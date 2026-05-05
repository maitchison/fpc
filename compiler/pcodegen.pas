{
    Codegen-proc parameter modifier (`feature/codegen-proc').

    Recognises `param: T codegen' inside the parameter list of a
    procedure or function and lowers it to a wrapper-around-renamed-orig
    pattern, building on top of ppreproc.pas's preprocessor framework.

    User syntax:

      function shl_add(a, b: longint; const c: byte codegen;
                                      const d: longint codegen): longint;
      label cg_c, cg_d;
      begin
          if cg_shl_add_addr_c = nil then begin
              cg_shl_add_addr_c := @cg_c;
              cg_shl_add_addr_d := @cg_d;
          end;
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

    What the preprocessor generates (in addition to renaming the
    user's procsym to a hidden name):

      var
          cg_shl_add_addr_c: pointer = nil;
          cg_shl_add_addr_d: pointer = nil;
          cg_shl_add_last_c: byte;
          cg_shl_add_last_d: longint;

      function shl_add(a, b: longint; const c: byte;
                                      const d: longint): longint;
      begin
          if cg_shl_add_addr_c = nil then
              cg_orig_shl_add_1(0, 0, 0, 0);   (* trigger publish *)
          if c <> cg_shl_add_last_c then begin
              PByte(cg_shl_add_addr_c)^ := c;
              cg_shl_add_last_c := c;
          end;
          if d <> cg_shl_add_last_d then begin
              PLongint(cg_shl_add_addr_d)^ := d;
              cg_shl_add_last_d := d;
          end;
          result := cg_orig_shl_add_1(a, b, c, d);
      end;

    Why this shape:

      * Pascal labels (`label cg_c, cg_d;') are addressable from
        Pascal context inside the declaring proc via `@cg_c'. We use
        them to expose the patch-site bytes to the wrapper.
      * The orig's first run publishes the addresses to global pointer
        vars; the wrapper reads through those pointers thereafter.
      * No `external name '...'' aliasing -- Pascal labels' mangled
        symbol names are unpredictable, so we sidestep the linker
        entirely.
      * Cache vars (`cg_<f>_last_<p>') zero-init match the placeholder
        bytes (`db 0' / `dd 0') zero-init, so the first compare is
        consistent: if c=0, no patch needed; if c<>0, patch fires.
        No `patched' flag required.

    User responsibility (v1):
      * Declare the proc's parameters as `const T codegen' (codegen
        params are byval-immutable).
      * Inside the proc, declare a Pascal `label' for each codegen
        param (needs `(*$goto on*)' or `-Sg' on the build).
      * The body's first statement must be the address-publish nil
        check, exactly as shown above. Naming convention:
            cg_<funcname>_addr_<paramname>
        is used by the wrapper to reach the published address.
      * The asm body uses the Pascal labels (`cg_<paramname>:') at the
        patch sites, with `db 0' / `dw 0' / `dd 0' placeholders.

    Hooks (registered in initialization):
      pp_at_param_modifier  -- parse + validate + sidecar + rename
      pp_after_proc_body    -- emit cache vars + addr vars + wrapper

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
      tpcodegen_param = record
        param_name: shortstring;
        param_def: tdef;
        type_size: longint;       { 1, 2, or 4 }
      end;

      tpcodegen_proc_entry = class
      public
        procdef: tprocdef;
        orig_name: shortstring;
        hidden_name: shortstring;
        params: array of tpcodegen_param;
        constructor create(apd: tprocdef);
      end;

    function pcodegen_find(pd: tprocdef): tpcodegen_proc_entry;

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

    function pcodegen_type_size(d: tdef): longint;
      var
        sz: asizeint;
      begin
        result := 0;
        if not is_ordinal(d) then
          exit;
        sz := d.size;
        if (sz = 1) or (sz = 2) or (sz = 4) then
          result := longint(sz);
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

    function pcodegen_rename_procsym(pd: tprocdef): shortstring;
      var
        psym: tprocsym;
        old_name: shortstring;
        n: longint;
      begin
        result := '';
        if not assigned(pd.procsym) then
          exit;
        psym := tprocsym(pd.procsym);
        old_name := psym.realname;
        n := 1;
        repeat
          result := 'cg_orig_' + old_name + '_' + tostr(n);
          inc(n);
        until psym.owner.find(upper(result)) = nil;
        psym.ChangeOwnerAndName(psym.owner, upper(result));
        psym.realname := result;
      end;

    { ============================================================
       pp_at_param_modifier handler
      ============================================================ }

    { Naming convention -- the user's source must match these:
        cg_<func>_addr_<param>     -- pointer var; orig publishes here
                                      on first call, wrapper reads here
        cg_<func>_last_<param>     -- cache var (compare pivot)
      Lowered names match user-typed Pascal identifier rules. }

    function addr_var_name(const orig_name, param_name: shortstring): shortstring;
      begin
        result := 'cg_' + orig_name + '_addr_' + param_name;
      end;

    function last_var_name(const orig_name, param_name: shortstring): shortstring;
      begin
        result := 'cg_' + orig_name + '_last_' + param_name;
      end;

    { ============================================================
       pp_before_proc_body handler -- splice label decls + publish
       prologue into the orig's body
      ============================================================ }

    { Manually consume tokens (with capture active) from the current
      scanner position until we hit `begin'. Decl-section tokens land
      in `buf' so they're replayed into the parser later as if the
      user had written them first. Returns true on success.

      Limitation: requires a `begin..end' body (rejects procs with
      the `assembler' directive whose body starts with `asm'
      directly). v1 acceptable. }
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

    function pcodegen_handle_before_body(ctx: pointer): boolean;
      var
        body_ctx: pppreproc_proc_body_ctx;
        pd: tprocdef;
        entry: tpcodegen_proc_entry;
        buf: tppreproc_buf;
        origin: tppreproc_origin;
        i: longint;
        first_addr: shortstring;
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
            { Conflicts with FPC's generic-body capture; not supported. }
            Comment(V_Error,
              'codegen-proc: cannot combine with a generic procedure');
            exit;
          end;

        origin.triggered_at := current_filepos;
        origin.feature := 'codegen-proc-prologue';
        buf := ppreproc_capture_begin(origin);

        { Step 1: capture all local-decl tokens (var/const/type/label/
          nested procs/etc.) into buf, stopping AT (not past) the
          body's `begin'. }
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

        { Step 2: append `label cg_<p1>, cg_<p2>, ...;' so the asm
          block's `cg_<p>:' label uses are valid Pascal labels. }
        ppreproc_emit_keyword(buf, _LABEL);
        for i := 0 to high(entry.params) do
          begin
            if i > 0 then
              ppreproc_emit_punct(buf, _COMMA);
            ppreproc_emit_ident(buf, 'cg_' + entry.params[i].param_name);
          end;
        ppreproc_emit_punct(buf, _SEMICOLON);

        { Step 3: emit our own `begin' (the user's `begin' is consumed
          below) followed by the address-publish nil check. }
        ppreproc_emit_keyword(buf, _BEGIN);

        first_addr := addr_var_name(entry.orig_name, entry.params[0].param_name);
        ppreproc_emit_keyword(buf, _IF);
        ppreproc_emit_ident(buf, first_addr);
        ppreproc_emit_punct(buf, _EQ);
        ppreproc_emit_keyword(buf, _NIL);
        ppreproc_emit_keyword(buf, _THEN);
        ppreproc_emit_keyword(buf, _BEGIN);
        for i := 0 to high(entry.params) do
          begin
            ppreproc_emit_ident(buf,
              addr_var_name(entry.orig_name, entry.params[i].param_name));
            ppreproc_emit_punct(buf, _ASSIGNMENT);
            ppreproc_emit_punct(buf, _KLAMMERAFFE);
            ppreproc_emit_ident(buf, 'cg_' + entry.params[i].param_name);
            ppreproc_emit_punct(buf, _SEMICOLON);
          end;
        ppreproc_emit_keyword(buf, _END);
        ppreproc_emit_punct(buf, _SEMICOLON);

        { Step 4: consume the user's `begin' so the parser, when it
          starts reading the buffer, sees OUR `begin' first, then
          falls back to user source for the rest of the body. }
        consume(_BEGIN);

        Comment(V_Debug,
          'codegen-proc: prologue spliced; buffer ' +
          tostr(buf.data.size) + ' bytes (' +
          tostr(length(entry.params)) + ' codegen params)');

        ppreproc_inject(buf);

        result := true;
      end;

    function pcodegen_handle_param_modifier(ctx: pointer): boolean;
      var
        param_ctx: pppreproc_param_modifier_ctx;
        pd: tprocdef;
        sc: TFPObjectList;
        hdef: tdef;
        vs: tparavarsym;
        entry: tpcodegen_proc_entry;
        sz: longint;
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

        sz := pcodegen_type_size(hdef);
        if sz = 0 then
          begin
            Comment(V_Error,
              'codegen-proc: parameter type must be ordinal of size ' +
              '1, 2, or 4 (byte/word/longint family)');
            consume(_CODEGEN);
            result := true;
            exit;
          end;

        vs := tparavarsym(sc[0]);

        if vs.varspez <> vs_const then
          begin
            Comment(V_Error,
              'codegen-proc: parameter "' + vs.realname +
              '" must be declared `const'' (codegen params are byval-immutable)');
            consume(_CODEGEN);
            result := true;
            exit;
          end;

        if assigned(pd.procsym) and
            (tprocsym(pd.procsym).ProcdefList.count > 0) then
          begin
            Comment(V_Error,
              'codegen-proc: cannot overload "' + pd.procsym.realname +
              '" with a non-codegen-proc version in the same scope');
            consume(_CODEGEN);
            result := true;
            exit;
          end;

        consume(_CODEGEN);

        entry := pcodegen_get_or_create(pd);
        if entry.orig_name = '' then
          begin
            if assigned(pd.procsym) then
              entry.orig_name := pd.procsym.realname;
            entry.hidden_name := pcodegen_rename_procsym(pd);
          end;
        pe_idx := length(entry.params);
        setlength(entry.params, pe_idx + 1);
        entry.params[pe_idx].param_name := vs.realname;
        entry.params[pe_idx].param_def := hdef;
        entry.params[pe_idx].type_size := sz;

        Comment(V_Debug,
          'codegen-proc: parameter "' + vs.realname +
          '" sized ' + tostr(sz) + ' on ' + entry.orig_name +
          ' -> ' + entry.hidden_name);

        result := true;
      end;

    { ============================================================
       Helpers for emitting the wrapper
      ============================================================ }

    type
      tcg_emit_param = record
        name: shortstring;
        typename: shortstring;
        spec: tvarspez;
        is_codegen: boolean;
      end;

    function collect_visible_params(pd: tprocdef;
                                    entry: tpcodegen_proc_entry;
                                    out emit_paras: array of tcg_emit_param;
                                    out count: longint): boolean;
      var
        i, j: longint;
        sym: tsym;
        ps: tparavarsym;
      begin
        result := true;
        count := 0;
        for i := 0 to pd.parast.SymList.count - 1 do
          begin
            sym := tsym(pd.parast.SymList[i]);
            if sym.typ <> paravarsym then
              continue;
            ps := tparavarsym(sym);
            if vo_is_hidden_para in ps.varoptions then
              continue;
            if not assigned(ps.vardef.typesym) then
              begin
                Comment(V_Error,
                  'codegen-proc: parameter "' + ps.realname +
                  '" has anonymous type; codegen-proc requires named ' +
                  'parameter types');
                result := false;
                exit;
              end;
            if count > high(emit_paras) then
              begin
                Comment(V_Error,
                  'codegen-proc: too many visible parameters');
                result := false;
                exit;
              end;
            emit_paras[count].name := ps.realname;
            emit_paras[count].typename := ps.vardef.typesym.realname;
            emit_paras[count].spec := ps.varspez;
            emit_paras[count].is_codegen := false;
            for j := 0 to high(entry.params) do
              if SameText(ps.realname, entry.params[j].param_name) then
                begin
                  emit_paras[count].is_codegen := true;
                  break;
                end;
            inc(count);
          end;
      end;

    procedure emit_param_spec(buf: tppreproc_buf; spec: tvarspez);
      begin
        case spec of
          vs_var:      ppreproc_emit_keyword(buf, _VAR);
          vs_const:    ppreproc_emit_keyword(buf, _CONST);
          vs_out:      ppreproc_emit_keyword(buf, _OUT);
          vs_constref: ppreproc_emit_ident(buf, 'constref');
          else
            ;
        end;
      end;

    procedure emit_addr_var(buf: tppreproc_buf;
                            const orig_name: shortstring;
                            const p: tpcodegen_param);
      var
        an: shortstring;
      begin
        an := addr_var_name(orig_name, p.param_name);
        ppreproc_emit_ident(buf, an);
        ppreproc_emit_punct(buf, _COLON);
        ppreproc_emit_ident(buf, 'pointer');
        ppreproc_emit_punct(buf, _SEMICOLON);
      end;

    procedure emit_last_var(buf: tppreproc_buf;
                            const orig_name: shortstring;
                            const p: tpcodegen_param);
      var
        ln, tn: shortstring;
      begin
        ln := last_var_name(orig_name, p.param_name);
        tn := pcodegen_size_typename(p.type_size);
        ppreproc_emit_ident(buf, ln);
        ppreproc_emit_punct(buf, _COLON);
        ppreproc_emit_ident(buf, tn);
        ppreproc_emit_punct(buf, _SEMICOLON);
      end;

    { Emit the trigger-publish call that runs once on first wrapper
      call. Uses zero literals for every param of the orig (the orig's
      body is expected to publish addresses unconditionally on its
      first call -- the user's nil-check ensures we only run it once). }
    procedure emit_publish_trigger(buf: tppreproc_buf;
                                   pd: tprocdef;
                                   entry: tpcodegen_proc_entry;
                                   const emit_paras: array of tcg_emit_param;
                                   paras_count: longint;
                                   is_function: boolean);
      var
        i: longint;
        first_addr: shortstring;
      begin
        if length(entry.params) = 0 then
          exit;
        first_addr := addr_var_name(entry.orig_name, entry.params[0].param_name);

        ppreproc_emit_keyword(buf, _IF);
        ppreproc_emit_ident(buf, first_addr);
        ppreproc_emit_punct(buf, _EQ);
        ppreproc_emit_keyword(buf, _NIL);
        ppreproc_emit_keyword(buf, _THEN);

        { Emit `<funcname> := <hidden>(0,...)' for functions, or
          a bare call for procedures. Function-name-assignment works
          in all FPC modes -- avoiding `result' sidesteps modeswitch
          dependency. }
        if is_function then
          begin
            ppreproc_emit_ident(buf, entry.orig_name);
            ppreproc_emit_punct(buf, _ASSIGNMENT);
          end;
        ppreproc_emit_ident(buf, entry.hidden_name);
        ppreproc_emit_punct(buf, _LKLAMMER);
        for i := 0 to paras_count - 1 do
          begin
            if i > 0 then
              ppreproc_emit_punct(buf, _COMMA);
            ppreproc_emit_intliteral(buf, 0);
          end;
        ppreproc_emit_punct(buf, _RKLAMMER);
        ppreproc_emit_punct(buf, _SEMICOLON);
      end;

    procedure emit_wrapper(buf: tppreproc_buf;
                           pd: tprocdef;
                           entry: tpcodegen_proc_entry;
                           const emit_paras: array of tcg_emit_param;
                           paras_count: longint);
      var
        i, j: longint;
        is_function: boolean;
        rettype_name: shortstring;
        ps: tpcodegen_param;
        ln, an, ptn: shortstring;
      begin
        is_function := false;
        rettype_name := '';
        if assigned(pd.returndef) and
           (not is_void(pd.returndef)) and
           assigned(pd.returndef.typesym) then
          begin
            is_function := true;
            rettype_name := pd.returndef.typesym.realname;
          end;

        if is_function then
          ppreproc_emit_keyword(buf, _FUNCTION)
        else
          ppreproc_emit_keyword(buf, _PROCEDURE);
        ppreproc_emit_ident(buf, entry.orig_name);

        ppreproc_emit_punct(buf, _LKLAMMER);
        for i := 0 to paras_count - 1 do
          begin
            if i > 0 then
              ppreproc_emit_punct(buf, _SEMICOLON);
            emit_param_spec(buf, emit_paras[i].spec);
            ppreproc_emit_ident(buf, emit_paras[i].name);
            ppreproc_emit_punct(buf, _COLON);
            ppreproc_emit_ident(buf, emit_paras[i].typename);
          end;
        ppreproc_emit_punct(buf, _RKLAMMER);

        if is_function then
          begin
            ppreproc_emit_punct(buf, _COLON);
            ppreproc_emit_ident(buf, rettype_name);
          end;
        ppreproc_emit_punct(buf, _SEMICOLON);

        ppreproc_emit_keyword(buf, _BEGIN);

        emit_publish_trigger(buf, pd, entry, emit_paras, paras_count, is_function);

        for j := 0 to high(entry.params) do
          begin
            ps := entry.params[j];
            ln := last_var_name(entry.orig_name, ps.param_name);
            an := addr_var_name(entry.orig_name, ps.param_name);
            ptn := pcodegen_size_ptype(ps.type_size);

            { if <p> <> <last> then begin
                P<sz>(<addr>)^ := <p>;
                <last> := <p>;
              end; }
            ppreproc_emit_keyword(buf, _IF);
            ppreproc_emit_ident(buf, ps.param_name);
            ppreproc_emit_punct(buf, _NE);
            ppreproc_emit_ident(buf, ln);
            ppreproc_emit_keyword(buf, _THEN);
            ppreproc_emit_keyword(buf, _BEGIN);

            { P<sz>(<addr>)^ := <p>; }
            ppreproc_emit_ident(buf, ptn);
            ppreproc_emit_punct(buf, _LKLAMMER);
            ppreproc_emit_ident(buf, an);
            ppreproc_emit_punct(buf, _RKLAMMER);
            ppreproc_emit_punct(buf, _CARET);
            ppreproc_emit_punct(buf, _ASSIGNMENT);
            ppreproc_emit_ident(buf, ps.param_name);
            ppreproc_emit_punct(buf, _SEMICOLON);

            { <last> := <p>; }
            ppreproc_emit_ident(buf, ln);
            ppreproc_emit_punct(buf, _ASSIGNMENT);
            ppreproc_emit_ident(buf, ps.param_name);
            ppreproc_emit_punct(buf, _SEMICOLON);

            ppreproc_emit_keyword(buf, _END);
            ppreproc_emit_punct(buf, _SEMICOLON);
          end;

        if is_function then
          begin
            ppreproc_emit_ident(buf, entry.orig_name);
            ppreproc_emit_punct(buf, _ASSIGNMENT);
          end;
        ppreproc_emit_ident(buf, entry.hidden_name);
        ppreproc_emit_punct(buf, _LKLAMMER);
        for i := 0 to paras_count - 1 do
          begin
            if i > 0 then
              ppreproc_emit_punct(buf, _COMMA);
            ppreproc_emit_ident(buf, emit_paras[i].name);
          end;
        ppreproc_emit_punct(buf, _RKLAMMER);
        ppreproc_emit_punct(buf, _SEMICOLON);

        ppreproc_emit_keyword(buf, _END);
        ppreproc_emit_punct(buf, _SEMICOLON);
      end;

    { ============================================================
       pp_after_proc_body handler -- emit + inject
      ============================================================ }

    function pcodegen_handle_after_body(ctx: pointer): boolean;
      var
        body_ctx: pppreproc_proc_body_ctx;
        pd: tprocdef;
        entry: tpcodegen_proc_entry;
        emit_paras: array[0..63] of tcg_emit_param;
        paras_count: longint;
        inject_buf: tppreproc_buf;
        inject_origin: tppreproc_origin;
        i: longint;
      begin
        paras_count := 0;
        fillchar(emit_paras, sizeof(emit_paras), 0);
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

        if not collect_visible_params(pd, entry, emit_paras, paras_count) then
          exit;

        inject_origin.triggered_at := current_filepos;
        inject_origin.feature := 'codegen-proc-emit';
        inject_buf := tppreproc_buf.create(inject_origin);

        ppreproc_emit_punct(inject_buf, _SEMICOLON);

        { Cache vars only -- the user is responsible for declaring
          the `cg_<f>_addr_<p>: pointer = nil;' vars BEFORE the orig
          (since the orig's body refers to them; forward references
          aren't possible across decl boundaries). }
        ppreproc_emit_keyword(inject_buf, _VAR);
        for i := 0 to high(entry.params) do
          emit_last_var(inject_buf, entry.orig_name, entry.params[i]);

        emit_wrapper(inject_buf, pd, entry, emit_paras, paras_count);

        if current_scanner.token = _SEMICOLON then
          consume(_SEMICOLON);

        Comment(V_Debug,
          'codegen-proc: inject buffer ' + tostr(inject_buf.data.size) +
          ' bytes (' + tostr(length(entry.params)) + ' codegen params)');

        ppreproc_inject(inject_buf);

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
    ppreproc_register(
      ppreproc_make_pass(
        'codegen-proc-after-body',
        pp_after_proc_body,
        NOTOKEN,
        NOTOKEN,
        @pcodegen_handle_after_body
      )
    );

finalization

    if assigned(entries) then
      entries.free;

end.
