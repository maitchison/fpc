{
    Codegen-proc parameter modifier (`feature/codegen-proc').

    Recognises `param: T codegen' (or `const param: T codegen' --
    `const' is auto-applied if absent) inside the parameter list of a
    procedure or function and lowers the proc into self-patching form:

      * Cache slot (writable typed-const, local to the proc) for each
        codegen param.
      * Pascal-label decl per codegen param so the asm body's
        `cg_<paramname>:' patch-site labels are addressable.
      * Pascal compare-and-patch prologue at the start of the proc
        body: if the new value differs from the cache, write it
        through `@cg_<paramname>' and update the cache.

    User syntax (everything else is preprocessor-emitted):

      function shl_add(a, b: longint;
                       c: byte    codegen;
                       d: longint codegen): longint;
      begin
          asm
              mov   eax, a
              db    $C1, $E0
      cg_c:
              db    0
              db    $69, $C0
      cg_d:
              dd    0
              add   eax, b
          end;
      end;

    Conceptual lowered form (the parser actually sees this -- the
    decl section + `begin' + prologue come from a preprocessor inject
    buffer, then control falls back to the user's asm block):

      function shl_add(a, b: longint;
                       const c: byte;
                       const d: longint): longint;
      label cg_c, cg_d;
      const
          cg_last_c: byte    = 0;
          cg_last_d: longint = 0;
      begin
          if c <> cg_last_c then begin
              PByte(@cg_c)^ := c;
              cg_last_c := c;
          end;
          if d <> cg_last_d then begin
              PLongint(@cg_d)^ := d;
              cg_last_d := d;
          end;
          asm
              mov eax, a
              ...
          end;
      end;

    Properties:
      * One proc, no wrapper. The orig itself does compare-and-patch.
      * Local writable typed-consts give per-proc cache storage with
        the lifetime we need (zero-init at unit load, mutable across
        calls). Requires writable typed constants -- on by default in
        FPC/Delphi modes; the user must enable it explicitly in
        ObjFPC mode if they want to use codegen-proc there.
      * `@cg_<paramname>' is a Pascal expression that resolves to the
        address of the asm-block label inside the same proc -- proven
        to work in FPC (see labprobe.pas notes in commit history).
      * Cache zero-init matches the placeholder bytes' zero-init, so
        the first compare is consistent: c=0 -> no patch needed
        (already 0); c<>0 -> patch fires.

    Hooks (registered in initialization):
      pp_at_param_modifier  -- validate, sidecar, auto-`const',
                               consume `codegen'
      pp_before_proc_body   -- splice label decls + cache consts +
                               compare-and-patch prologue into the
                               body via manual consume + emit + inject

    User burden:
      * Add `codegen' to the relevant parameters.
      * Use `cg_<paramname>:' as the label name in the asm body at
        each patch site, with `db 0' / `dw 0' / `dd 0' placeholder
        of the param's width.
      * Build with `-Sg' (label/goto support).

    Sidecar lifetime: process-global. Keyed by procdef pointer.
}
unit pcodegen;

{$i fpcdefs.inc}

interface

    uses
      cclasses,
      symtype,
      symdef,
      ppreproc;

    type
      tpcodegen_kind = (
        { Ordinal byte/word/longint param. Used as the immediate
          operand of an instruction (`shl reg, p', `imul r,r,p',
          `add reg, p'). Patched at the imm bytes embedded in the
          encoded instruction. }
        cgk_imm,
        { Pointer param. Used as a memory-reference base address
          (`mov eax, p[ebx*2]'). Patched at the disp32 bytes of the
          encoded instruction. Always 4-byte displacement on i386. }
        cgk_ptr
      );

      tpcodegen_param = record
        param_name: shortstring;
        param_def: tdef;
        type_size: longint;       { 1, 2, or 4 }
        kind: tpcodegen_kind;
      end;

      tpcodegen_proc_entry = class
      public
        procdef: tprocdef;
        params: array of tpcodegen_param;
        constructor create(apd: tprocdef);
      end;

    function pcodegen_find(pd: tprocdef): tpcodegen_proc_entry;

    { Lookup helper for the asm reader: if `ident' (case-insensitive)
      matches a codegen param of `pd', returns true and sets the
      param's byte width + the auto-generated patch-site label name.
      Returns false otherwise. The label name is `cg_<paramname>'
      (the same name the preprocessor injects via `label cg_<p>;'). }
    function pcodegen_match_param(pd: tprocdef;
                                  const ident: string;
                                  out kind: tpcodegen_kind;
                                  out type_size: longint;
                                  out label_name: shortstring): boolean;

implementation

    uses
      sysutils,
      globtype,
      globals,
      tokens,
      verbose,
      cutils,
      scanner,
      pbase,
      symbase,
      symsym,
      symconst,
      defutil;

    var
      entries: TFPObjectList = nil;

    constructor tpcodegen_proc_entry.create(apd: tprocdef);
      begin
        inherited create;
        procdef := apd;
      end;

    function pcodegen_find(pd: tprocdef): tpcodegen_proc_entry;
      var
        i: longint;
      begin
        result := nil;
        if not assigned(entries) then
          exit;
        for i := 0 to entries.count - 1 do
          if tpcodegen_proc_entry(entries[i]).procdef = pd then
            begin
              result := tpcodegen_proc_entry(entries[i]);
              exit;
            end;
      end;

    function pcodegen_match_param(pd: tprocdef;
                                  const ident: string;
                                  out kind: tpcodegen_kind;
                                  out type_size: longint;
                                  out label_name: shortstring): boolean;
      var
        e: tpcodegen_proc_entry;
        i: longint;
      begin
        result := false;
        kind := cgk_imm;
        type_size := 0;
        label_name := '';
        if pd = nil then
          exit;
        e := pcodegen_find(pd);
        if e = nil then
          exit;
        for i := 0 to high(e.params) do
          if SameText(ident, e.params[i].param_name) then
            begin
              kind := e.params[i].kind;
              type_size := e.params[i].type_size;
              label_name := 'cg_' + e.params[i].param_name;
              result := true;
              exit;
            end;
      end;

    function pcodegen_get_or_create(pd: tprocdef): tpcodegen_proc_entry;
      begin
        result := pcodegen_find(pd);
        if result = nil then
          begin
            result := tpcodegen_proc_entry.create(pd);
            if not assigned(entries) then
              entries := TFPObjectList.create(true);
            entries.add(result);
          end;
      end;

    { Classify a codegen-param's type. Returns the byte width AND
      sets the kind:
        cgk_imm: ordinal of size 1, 2, or 4 (byte/word/longint family)
        cgk_ptr: any pointer type (size 4 on i386 / go32v2)
      Returns 0 (and leaves kind undefined) for unsupported types. }
    function pcodegen_classify(d: tdef; out kind: tpcodegen_kind): longint;
      var
        sz: asizeint;
      begin
        result := 0;
        kind := cgk_imm;
        if d = nil then
          exit;
        if is_pointer(d) then
          begin
            sz := d.size;
            if sz = sizeof(pointer) then
              begin
                kind := cgk_ptr;
                result := longint(sz);
              end;
            exit;
          end;
        if not is_ordinal(d) then
          exit;
        sz := d.size;
        if (sz = 1) or (sz = 2) or (sz = 4) then
          begin
            kind := cgk_imm;
            result := longint(sz);
          end;
      end;

    function pcodegen_size_typename(sz: longint): shortstring;
      begin
        case sz of
          1: result := 'byte';
          2: result := 'word';
          4: result := 'longint';
        else
          result := '';
        end;
      end;

    function pcodegen_size_ptype(sz: longint): shortstring;
      begin
        case sz of
          1: result := 'PByte';
          2: result := 'PWord';
          4: result := 'PLongint';
        else
          result := '';
        end;
      end;

    function label_name_for(const param_name: shortstring): shortstring;
      begin
        result := 'cg_' + param_name;
      end;

    function cache_name_for(const param_name: shortstring): shortstring;
      begin
        result := 'cg_last_' + param_name;
      end;

    { ============================================================
       pp_at_param_modifier handler
      ============================================================ }

    function pcodegen_handle_param_modifier(ctx: pointer): boolean;
      var
        param_ctx: pppreproc_param_modifier_ctx;
        pd: tprocdef;
        sc: TFPObjectList;
        hdef: tdef;
        vs: tparavarsym;
        entry: tpcodegen_proc_entry;
        sz: longint;
        kind: tpcodegen_kind;
        pe_idx: longint;
      begin
        result := false;

        if not ((current_scanner.token = _ID) and
                (current_scanner.idtoken = _CODEGEN)) then
          exit;

        if not assigned(ctx) then
          exit;
        param_ctx := pppreproc_param_modifier_ctx(ctx);

        if not (param_ctx^.procdef is tprocdef) then
          begin
            Comment(V_Error,
              'codegen-proc: only allowed on procedure/function ' +
              'parameters, not on procvar types');
            consume(_CODEGEN);
            result := true;
            exit;
          end;

        pd := tprocdef(param_ctx^.procdef);
        sc := TFPObjectList(param_ctx^.param_syms);
        hdef := tdef(param_ctx^.param_type);

        if assigned(pd.struct) then
          begin
            Comment(V_Error,
              'codegen-proc: not yet supported on methods (v1)');
            consume(_CODEGEN);
            result := true;
            exit;
          end;

        if (sc = nil) or (sc.count <> 1) then
          begin
            Comment(V_Error,
              'codegen-proc: must apply to exactly one parameter ' +
              '(split comma groups)');
            consume(_CODEGEN);
            result := true;
            exit;
          end;

        sz := pcodegen_classify(hdef, kind);
        if sz = 0 then
          begin
            Comment(V_Error,
              'codegen-proc: parameter type must be ordinal of size ' +
              '1, 2, or 4 (byte/word/longint family) OR a pointer type');
            consume(_CODEGEN);
            result := true;
            exit;
          end;

        vs := tparavarsym(sc[0]);

        { Auto-apply `const'. The user shouldn't need to write it; a
          codegen param is byval-immutable by definition. Reject `var'
          and `out' explicitly because those imply addressable-storage
          semantics that conflict with patched-immediate use. }
        case vs.varspez of
          vs_const:
            ;  { already const, nothing to do }
          vs_value:
            vs.varspez := vs_const;  { auto-promote }
          vs_var, vs_out:
            begin
              Comment(V_Error,
                'codegen-proc: parameter "' + vs.realname +
                '" cannot be `var'' / `out'' (codegen params are ' +
                'byval-immutable)');
              consume(_CODEGEN);
              result := true;
              exit;
            end;
          else
            begin
              Comment(V_Error,
                'codegen-proc: parameter "' + vs.realname +
                '" has unsupported varspez');
              consume(_CODEGEN);
              result := true;
              exit;
            end;
        end;

        consume(_CODEGEN);

        entry := pcodegen_get_or_create(pd);
        pe_idx := length(entry.params);
        setlength(entry.params, pe_idx + 1);
        entry.params[pe_idx].param_name := vs.realname;
        entry.params[pe_idx].param_def := hdef;
        entry.params[pe_idx].type_size := sz;
        entry.params[pe_idx].kind := kind;

        if kind = cgk_ptr then
          Comment(V_Debug,
            'codegen-proc: pointer parameter "' + vs.realname +
            '" (disp32 patch site)')
        else
          Comment(V_Debug,
            'codegen-proc: parameter "' + vs.realname +
            '" sized ' + tostr(sz));

        result := true;
      end;

    { ============================================================
       pp_before_proc_body handler -- splice prologue into body
      ============================================================ }

    { Manually consume tokens (with capture active) from the current
      scanner position until we hit `begin'. Decl-section tokens land
      in `buf' so they're replayed into the parser later as if the
      user had written them first. Returns true if `begin' was reached. }
    function consume_decls_until_begin(buf: tppreproc_buf): boolean;
      var
        t: ttoken;
      begin
        result := false;
        while true do
          begin
            t := current_scanner.token;
            if t = _BEGIN then
              begin
                result := true;
                exit;
              end;
            if (t = _ASM) or (t = _EOF) then
              exit;
            consume(t);
          end;
      end;

    { Emit `label cg_<p1>, cg_<p2>, ...;' so the asm body's
      `cg_<paramname>:' uses are valid Pascal labels. }
    procedure emit_label_decls(buf: tppreproc_buf;
                               entry: tpcodegen_proc_entry);
      var
        i: longint;
      begin
        ppreproc_emit_keyword(buf, _LABEL);
        for i := 0 to high(entry.params) do
          begin
            if i > 0 then
              ppreproc_emit_punct(buf, _COMMA);
            ppreproc_emit_ident(buf, label_name_for(entry.params[i].param_name));
          end;
        ppreproc_emit_punct(buf, _SEMICOLON);
      end;

    { Emit `const cg_last_<p1>: <type> = 0; cg_last_<p2>: ...;' --
      writable typed-constants give per-proc storage with zero-init
      that survives across calls. Matches the patch-byte placeholder
      zero-init so the first compare is consistent. }
    procedure emit_cache_consts(buf: tppreproc_buf;
                                entry: tpcodegen_proc_entry);
      var
        i: longint;
        ps: tpcodegen_param;
      begin
        ppreproc_emit_keyword(buf, _CONST);
        for i := 0 to high(entry.params) do
          begin
            ps := entry.params[i];
            ppreproc_emit_ident(buf, cache_name_for(ps.param_name));
            ppreproc_emit_punct(buf, _COLON);
            if ps.kind = cgk_ptr then
              begin
                { pointer cache: `cg_last_p: pointer = nil;' }
                ppreproc_emit_ident(buf, 'pointer');
                ppreproc_emit_punct(buf, _EQ);
                ppreproc_emit_keyword(buf, _NIL);
              end
            else
              begin
                ppreproc_emit_ident(buf, pcodegen_size_typename(ps.type_size));
                ppreproc_emit_punct(buf, _EQ);
                ppreproc_emit_intliteral(buf, 0);
              end;
            ppreproc_emit_punct(buf, _SEMICOLON);
          end;
      end;

    { Emit, for each codegen param `p' of width N:
        if p <> cg_last_p then begin
          P<sz>(@cg_p)^ := p;
          cg_last_p := p;
        end;
      Pre: `begin' has been emitted on `buf'; this is the body's
      first compound-statement region. }
    procedure emit_compare_patch_block(buf: tppreproc_buf;
                                       entry: tpcodegen_proc_entry);
      var
        i: longint;
        ps: tpcodegen_param;
        ln, cn, ptn: shortstring;
      begin
        for i := 0 to high(entry.params) do
          begin
            ps := entry.params[i];
            ln := label_name_for(ps.param_name);
            cn := cache_name_for(ps.param_name);
            { Pointer params use PPointer to land on the disp32; ordinal
              imm params use PByte/PWord/PLongint to land on the imm
              bytes. The "back up by 1 stride" trick puts us at the
              start of the patch field for both: pointer = 4 bytes
              before the post-instruction label, longint = 4 bytes,
              word = 2, byte = 1. }
            if ps.kind = cgk_ptr then
              ptn := 'PPointer'
            else
              ptn := pcodegen_size_ptype(ps.type_size);

            ppreproc_emit_keyword(buf, _IF);
            ppreproc_emit_ident(buf, ps.param_name);
            ppreproc_emit_punct(buf, _NE);
            ppreproc_emit_ident(buf, cn);
            ppreproc_emit_keyword(buf, _THEN);
            ppreproc_emit_keyword(buf, _BEGIN);

            { (PType(@<label>) - 1)^ := p;
              The label is emitted by the asm reader IMMEDIATELY AFTER
              the patched instruction (i.e. one step PAST the patch
              bytes), so we back up by one PType stride. }
            ppreproc_emit_punct(buf, _LKLAMMER);
            ppreproc_emit_ident(buf, ptn);
            ppreproc_emit_punct(buf, _LKLAMMER);
            ppreproc_emit_punct(buf, _KLAMMERAFFE);
            ppreproc_emit_ident(buf, ln);
            ppreproc_emit_punct(buf, _RKLAMMER);
            ppreproc_emit_punct(buf, _MINUS);
            ppreproc_emit_intliteral(buf, 1);
            ppreproc_emit_punct(buf, _RKLAMMER);
            ppreproc_emit_punct(buf, _CARET);
            ppreproc_emit_punct(buf, _ASSIGNMENT);
            ppreproc_emit_ident(buf, ps.param_name);
            ppreproc_emit_punct(buf, _SEMICOLON);

            { cg_last_p := p; }
            ppreproc_emit_ident(buf, cn);
            ppreproc_emit_punct(buf, _ASSIGNMENT);
            ppreproc_emit_ident(buf, ps.param_name);
            ppreproc_emit_punct(buf, _SEMICOLON);

            ppreproc_emit_keyword(buf, _END);
            ppreproc_emit_punct(buf, _SEMICOLON);
          end;
      end;

    function pcodegen_handle_before_body(ctx: pointer): boolean;
      var
        body_ctx: pppreproc_proc_body_ctx;
        pd: tprocdef;
        entry: tpcodegen_proc_entry;
        buf: tppreproc_buf;
        origin: tppreproc_origin;
      begin
        result := false;
        if not assigned(ctx) then
          exit;
        body_ctx := pppreproc_proc_body_ctx(ctx);
        if not (body_ctx^.procdef is tprocdef) then
          exit;
        pd := tprocdef(body_ctx^.procdef);
        entry := pcodegen_find(pd);
        if entry = nil then
          exit;
        if length(entry.params) = 0 then
          exit;
        if current_scanner.is_recording_tokens then
          begin
            Comment(V_Error,
              'codegen-proc: cannot combine with a generic procedure');
            exit;
          end;

        origin.triggered_at := current_filepos;
        origin.feature := 'codegen-proc-prologue';
        buf := ppreproc_capture_begin(origin);

        { Capture user's local-decl section into buf, stopping AT
          (not past) `begin'. }
        if not consume_decls_until_begin(buf) then
          begin
            ppreproc_capture_end(buf);
            buf.free;
            Comment(V_Error,
              'codegen-proc: requires `begin..end'' body (procs with ' +
              'the `assembler'' directive aren''t supported in v1)');
            exit;
          end;

        ppreproc_capture_end(buf);

        { Append synthesised local decls + new `begin' + prologue. }
        emit_label_decls(buf, entry);
        emit_cache_consts(buf, entry);

        ppreproc_emit_keyword(buf, _BEGIN);
        emit_compare_patch_block(buf, entry);

        { Consume the user's `begin' so once buf drains, the parser
          continues from user source at "first statement of body". }
        consume(_BEGIN);

        Comment(V_Debug,
          'codegen-proc: prologue spliced; buffer ' +
          tostr(buf.data.size) + ' bytes (' +
          tostr(length(entry.params)) + ' codegen params)');

        ppreproc_inject(buf);

        result := true;
      end;

initialization

    ppreproc_register(
      ppreproc_make_pass(
        'codegen-proc',
        pp_at_param_modifier,
        _ID,
        _CODEGEN,
        @pcodegen_handle_param_modifier
      )
    );
    ppreproc_register(
      ppreproc_make_pass(
        'codegen-proc-before-body',
        pp_before_proc_body,
        NOTOKEN,
        NOTOKEN,
        @pcodegen_handle_before_body
      )
    );

finalization

    if assigned(entries) then
      entries.free;

end.
