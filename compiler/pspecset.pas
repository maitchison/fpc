{
    Specialize-set parameter modifier.

    Recognises `param: T specialize [v1, v2, .., a..b]' inside a
    parameter list and lowers it to:

      * N specialised wrapper procedures (one per set value), each
        an exact clone of the user's body with the parameter
        shadowed by `const k = <v>;' so FPC's normal const-folding
        kicks in inside.
      * One dispatch stub with the user's original signature, body
        is `case k of <v>: f__K_<v>(<args minus k>); ... end' --
        marked `inline' so constant call sites fold to a direct
        call to the matching wrapper, runtime call sites become a
        case-table jump.

    Implementation is a pure preprocessor pass: no AST surgery, no
    procdef-internals tweaking beyond renaming the user's procsym
    so the injected dispatch stub can take the user-visible name.
    Everything else flows through ppreproc.pas's
    capture/inject/emit primitives.

    Hooks (registered in initialization):

      pp_at_param_modifier  -- parse + validate + sidecar
      pp_before_proc_body   -- ppreproc_capture_begin (body capture)
      pp_after_proc_body    -- emit wrappers + stub, inject

    Sidecar lifetime: process-global. Keyed by procdef pointer.
    Memory cost trivial (one entry per specialize-set-bearing proc).
}
unit pspecset;

{$i fpcdefs.inc}

interface

    uses
      cclasses,
      symtype,
      symdef,
      ppreproc;

    type
      { One specialize-set parameter on a procdef. param_def is the
        parameter's declared type (e.g. integer); values is the flat
        expansion of the set literal (ranges expanded). }
      tpspecset_param_entry = record
        param_name: shortstring;
        param_def: tdef;
        values: array of int64;
      end;

      tpspecset_proc_entry = class
      public
        procdef: tprocdef;
        { User's original procsym name, captured BEFORE the
          rename-to-hidden in pp_at_param_modifier. The dispatch
          stub takes this name back. }
        orig_name: shortstring;
        params: array of tpspecset_param_entry;
        { Body-capture buffer, set in pp_before_proc_body, finalised
          in pp_after_proc_body. nil if no capture is active. }
        body_buf: tppreproc_buf;
        constructor create(apd: tprocdef);
        destructor destroy; override;
      end;

    { Lookup the sidecar entry for a procdef, or nil if none was
      registered. Safe to call before the entry list is initialised. }
    function pspecset_find(pd: tprocdef): tpspecset_proc_entry;

    { Total cardinality across the cartesian product of all the
      procdef's specialize-set params. Returns 1 if there are no
      such params (degenerate). }
    function pspecset_total_count(entry: tpspecset_proc_entry): longint;

    const
      { Hard cap on total specialisations across the cartesian
        product of all specialize-set params on one proc. The spec
        derives this from "code size has to stay bounded". }
      PSPECSET_MAX_VALUES = 64;

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
      pexpr,
      symbase,
      symsym,
      symconst,
      defutil,
      constexp,
      node,
      ncon;

    var
      { Master sidecar list. Created lazily on first attach.
        Owned: TFPObjectList(true) frees its entries on destroy. }
      entries: TFPObjectList = nil;

    constructor tpspecset_proc_entry.create(apd: tprocdef);
      begin
        inherited create;
        procdef := apd;
        body_buf := nil;
      end;

    destructor tpspecset_proc_entry.destroy;
      begin
        if assigned(body_buf) then
          begin
            body_buf.free;
            body_buf := nil;
          end;
        inherited destroy;
      end;

    function pspecset_find(pd: tprocdef): tpspecset_proc_entry;
      var
        i: longint;
      begin
        result := nil;
        if not assigned(entries) then
          exit;
        for i := 0 to entries.count - 1 do
          if tpspecset_proc_entry(entries[i]).procdef = pd then
            begin
              result := tpspecset_proc_entry(entries[i]);
              exit;
            end;
      end;

    function pspecset_get_or_create(pd: tprocdef): tpspecset_proc_entry;
      begin
        result := pspecset_find(pd);
        if result = nil then
          begin
            result := tpspecset_proc_entry.create(pd);
            if not assigned(entries) then
              entries := TFPObjectList.create(true);
            entries.add(result);
          end;
      end;

    function pspecset_total_count(entry: tpspecset_proc_entry): longint;
      var
        i: longint;
      begin
        if (entry = nil) or (length(entry.params) = 0) then
          begin
            result := 1;
            exit;
          end;
        result := 1;
        for i := 0 to high(entry.params) do
          result := result * length(entry.params[i].values);
      end;

    { ============================================================
       Set-body parser (used by pp_at_param_modifier handler)
      ============================================================ }

    procedure pspecset_skip_set_body;
      var
        depth: longint;
      begin
        depth := 1;
        while (depth > 0) and (current_scanner.token <> _EOF) do
          begin
            case current_scanner.token of
              _LECKKLAMMER:
                inc(depth);
              _RECKKLAMMER:
                begin
                  dec(depth);
                  if depth = 0 then
                    break;
                end;
              else
                ;
            end;
            consume(current_scanner.token);
          end;
        if current_scanner.token = _RECKKLAMMER then
          consume(_RECKKLAMMER);
      end;

    function parse_set_body(var values: array of int64;
                            var nvalues: longint;
                            const max_values: longint): boolean;
      var
        lower_node, upper_node: tnode;
        lower_val, upper_val, v: int64;
        i: int64;
      begin
        result := false;
        nvalues := 0;

        if current_scanner.token = _RECKKLAMMER then
          begin
            Comment(V_Error,
              'specialize-set: at least one value is required');
            consume(_RECKKLAMMER);
            exit;
          end;

        repeat
          lower_node := comp_expr([]);
          if lower_node.nodetype <> ordconstn then
            begin
              Comment(V_Error,
                'specialize-set: ordinal constant expected');
              lower_node.free;
              pspecset_skip_set_body;
              exit;
            end;
          lower_val := tordconstnode(lower_node).value.svalue;
          lower_node.free;

          if current_scanner.token = _POINTPOINT then
            begin
              consume(_POINTPOINT);
              upper_node := comp_expr([]);
              if upper_node.nodetype <> ordconstn then
                begin
                  Comment(V_Error,
                    'specialize-set: ordinal constant expected after `..''');
                  upper_node.free;
                  pspecset_skip_set_body;
                  exit;
                end;
              upper_val := tordconstnode(upper_node).value.svalue;
              upper_node.free;
              if upper_val < lower_val then
                begin
                  Comment(V_Error,
                    'specialize-set: range upper bound is less than lower');
                  pspecset_skip_set_body;
                  exit;
                end;
            end
          else
            upper_val := lower_val;

          v := lower_val;
          while v <= upper_val do
            begin
              if nvalues >= max_values then
                begin
                  Comment(V_Error,
                    'specialize-set: too many values (cap is ' +
                    tostr(max_values) + ')');
                  pspecset_skip_set_body;
                  exit;
                end;
              i := 0;
              while i < nvalues do
                begin
                  if values[i] = v then
                    break;
                  inc(i);
                end;
              if i = nvalues then
                begin
                  values[nvalues] := v;
                  inc(nvalues);
                end;
              inc(v);
            end;

          if current_scanner.token = _COMMA then
            consume(_COMMA)
          else
            break;
        until false;

        if current_scanner.token <> _RECKKLAMMER then
          begin
            Comment(V_Error,
              'specialize-set: `]'' expected');
            pspecset_skip_set_body;
            exit;
          end;

        consume(_RECKKLAMMER);
        result := true;
      end;

    { ============================================================
       pp_at_param_modifier handler (SS-A)
      ============================================================ }

    { Rename pd's procsym to a unique hidden name so:
        * The user-visible original name is freed up for the
          to-be-injected dispatch stub.
        * proc_set_mangledname (called LATER, in psub.pas:3061 after
          parse_proc_head finishes) sees the renamed procsym and
          assigns a unique mangled label -- no collision with the
          dispatch stub's eventual symbol.

      MUST be called from SS-A's pp_at_param_modifier handler, BEFORE
      mangling happens. Calling later trips internalerror 200411171
      in tprocdef.setmangledname (mangled name is frozen once set). }
    procedure rename_user_procsym_unique(pd: tprocdef);
      var
        psym: tprocsym;
        old_name: shortstring;
        hidden_name: shortstring;
        n: longint;
      begin
        if not assigned(pd.procsym) then
          exit;
        psym := tprocsym(pd.procsym);
        old_name := psym.realname;
        n := 1;
        repeat
          hidden_name := '$specset_orig_' + old_name + '_' + tostr(n);
          inc(n);
        until psym.owner.find(hidden_name) = nil;
        psym.ChangeOwnerAndName(psym.owner, upper(hidden_name));
        psym.realname := hidden_name;
      end;

    function pspecset_handle_param_modifier(ctx: pointer): boolean;
      var
        param_ctx: pppreproc_param_modifier_ctx;
        pd: tprocdef;
        sc: TFPObjectList;
        hdef: tdef;
        vs: tparavarsym;
        values: array of int64;
        nvalues: longint;
        entry: tpspecset_proc_entry;
        existing_count, new_count, total: longint;
        pe_idx, i: longint;
      begin
        result := false;

        if not ((current_scanner.token = _ID) and
                (current_scanner.idtoken = _SPECIALIZE)) then
          exit;

        if not assigned(ctx) then
          exit;
        param_ctx := pppreproc_param_modifier_ctx(ctx);

        if not (param_ctx^.procdef is tprocdef) then
          begin
            Comment(V_Error,
              'specialize-set: only allowed on procedure/function ' +
              'parameters, not on procvar types');
            consume(_SPECIALIZE);
            if current_scanner.token = _LECKKLAMMER then
              begin
                consume(_LECKKLAMMER);
                pspecset_skip_set_body;
              end;
            result := true;
            exit;
          end;

        pd := tprocdef(param_ctx^.procdef);
        sc := TFPObjectList(param_ctx^.param_syms);
        hdef := tdef(param_ctx^.param_type);

        { Reject methods (class/record/object) entirely in v1. The
          spec specifically calls out virtual -- which would require
          all N wrappers + the dispatch stub to live in the same
          vtable slot. We can't even check po_virtualmethod here
          because the `virtual' directive is parsed AFTER the
          parameter list, so at SS-A time procoptions is incomplete.
          Plus the desugar emits free top-level decls, which won't
          attach to the class's symtable correctly. Reject all
          struct-bound procs up-front; revisit non-virtual methods
          in v2 if needed. }
        if assigned(pd.struct) then
          begin
            Comment(V_Error,
              'specialize-set: not yet supported on methods (v1)');
            consume(_SPECIALIZE);
            if current_scanner.token = _LECKKLAMMER then
              begin
                consume(_LECKKLAMMER);
                pspecset_skip_set_body;
              end;
            result := true;
            exit;
          end;

        { Reject overload conflicts. At SS-A time pd is not yet in
          procsym.ProcdefList (proc_add_definition runs later); any
          entries already there are PRIOR overloads with the same
          name. Mixing specialize-set with non-specialize-set
          overloads triggers ambiguous resolution at call sites, so
          reject up-front. }
        if assigned(pd.procsym) and
            (tprocsym(pd.procsym).ProcdefList.count > 0) then
          begin
            Comment(V_Error,
              'specialize-set: cannot overload "' +
              pd.procsym.realname +
              '" with a non-specialize-set version in the same scope');
            consume(_SPECIALIZE);
            if current_scanner.token = _LECKKLAMMER then
              begin
                consume(_LECKKLAMMER);
                pspecset_skip_set_body;
              end;
            result := true;
            exit;
          end;

        if (sc = nil) or (sc.count <> 1) then
          begin
            Comment(V_Error,
              'specialize-set: must apply to exactly one parameter ' +
              '(split comma groups)');
            consume(_SPECIALIZE);
            if current_scanner.token = _LECKKLAMMER then
              begin
                consume(_LECKKLAMMER);
                pspecset_skip_set_body;
              end;
            result := true;
            exit;
          end;

        if not is_ordinal(hdef) then
          begin
            Comment(V_Error,
              'specialize-set: parameter type must be ordinal');
            consume(_SPECIALIZE);
            if current_scanner.token = _LECKKLAMMER then
              begin
                consume(_LECKKLAMMER);
                pspecset_skip_set_body;
              end;
            result := true;
            exit;
          end;

        vs := tparavarsym(sc[0]);

        consume(_SPECIALIZE);
        if current_scanner.token <> _LECKKLAMMER then
          begin
            Comment(V_Error,
              'specialize-set: `['' expected');
            result := true;
            exit;
          end;
        consume(_LECKKLAMMER);

        entry := pspecset_find(pd);
        if entry = nil then
          existing_count := 1
        else
          existing_count := pspecset_total_count(entry);

        setlength(values, PSPECSET_MAX_VALUES);
        nvalues := 0;
        if not parse_set_body(values, nvalues, PSPECSET_MAX_VALUES) then
          begin
            result := true;
            exit;
          end;

        new_count := nvalues;
        total := existing_count * new_count;
        if total > PSPECSET_MAX_VALUES then
          begin
            Comment(V_Error,
              'specialize-set: cartesian product exceeds cap ' +
              '(' + tostr(total) + ' > ' + tostr(PSPECSET_MAX_VALUES) + ')');
            result := true;
            exit;
          end;

        entry := pspecset_get_or_create(pd);
        if entry.orig_name = '' then
          begin
            { First specialize-set modifier on this proc. Save the
              user's name and rename the procsym so proc_set_mangledname
              (which runs LATER, after parse_proc_head finishes) gets
              the renamed name and assigns a unique mangled label. }
            if assigned(pd.procsym) then
              entry.orig_name := pd.procsym.realname;
            rename_user_procsym_unique(pd);
          end;
        pe_idx := length(entry.params);
        setlength(entry.params, pe_idx + 1);
        entry.params[pe_idx].param_name := vs.realname;
        entry.params[pe_idx].param_def := hdef;
        setlength(entry.params[pe_idx].values, nvalues);
        for i := 0 to nvalues - 1 do
          entry.params[pe_idx].values[i] := values[i];

        Comment(V_Debug,
          'specialize-set: parameter "' + vs.realname +
          '" -- ' + tostr(nvalues) + ' values, cartesian total ' +
          tostr(pspecset_total_count(entry)));

        result := true;
      end;

    { ============================================================
       pp_before_proc_body handler -- start body capture
      ============================================================ }

    function pspecset_handle_before_body(ctx: pointer): boolean;
      var
        body_ctx: pppreproc_proc_body_ctx;
        pd: tprocdef;
        entry: tpspecset_proc_entry;
        origin: tppreproc_origin;
      begin
        result := false;
        if not assigned(ctx) then
          exit;
        body_ctx := pppreproc_proc_body_ctx(ctx);
        if not (body_ctx^.procdef is tprocdef) then
          exit;
        pd := tprocdef(body_ctx^.procdef);
        entry := pspecset_find(pd);
        if entry = nil then
          exit;
        if length(entry.params) = 0 then
          exit;
        if assigned(entry.body_buf) then
          { defensive: capture already in progress for this procdef }
          exit;
        if current_scanner.is_recording_tokens then
          begin
            { conflict with FPC's generic-body capture; not supported in v1 }
            Comment(V_Error,
              'specialize-set: cannot combine with a generic procedure');
            exit;
          end;

        origin.triggered_at := current_filepos;
        origin.feature := 'specialize-set-body';
        entry.body_buf := ppreproc_capture_begin(origin);
        Comment(V_Debug, 'specialize-set: body capture begun');
        result := true;
      end;

    { ============================================================
       Helpers for emitting wrappers + dispatch stub
      ============================================================ }

    type
      tspecset_emit_param = record
        name: shortstring;
        typename: shortstring;
        spec: tvarspez;
        is_specparam: boolean;
      end;

    { Append the captured body buffer into `dst' verbatim. The source
      buffer's read pointer is preserved. }
    procedure copy_buf_into(dst, src: tppreproc_buf);
      var
        savepos: longword;
        b: byte;
      begin
        if not assigned(src) then
          exit;
        savepos := src.data.pos;
        src.data.seek(0);
        while src.data.pos < src.data.size do
          begin
            src.data.read(b, 1);
            dst.data.write(b, 1);
          end;
        src.data.seek(savepos);
      end;

    { Walk pd.parast.SymList and collect ALL visible (non-hidden)
      parameters in source order. The one named kname is flagged
      via is_specparam. typename is taken from the parameter's vardef.typesym
      -- types without a typesym (anonymous types) cause emission to
      be aborted with an error (returns false). }
    function collect_visible_params(pd: tprocdef;
                                    const kname: shortstring;
                                    out emit_paras: array of tspecset_emit_param;
                                    out count: longint): boolean;
      var
        i: longint;
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
                  'specialize-set: parameter "' + ps.realname +
                  '" has anonymous type; specialize-set requires named ' +
                  'parameter types');
                result := false;
                exit;
              end;
            if count > high(emit_paras) then
              begin
                Comment(V_Error,
                  'specialize-set: too many visible parameters');
                result := false;
                exit;
              end;
            emit_paras[count].name := ps.realname;
            emit_paras[count].typename := ps.vardef.typesym.realname;
            emit_paras[count].spec := ps.varspez;
            emit_paras[count].is_specparam := SameText(ps.realname, kname);
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

    { Emit:
        procedure <wrapper_name>(<sig minus k>); inline;
        const <kname> = <v>;
        <body tokens>
      The body is a cloned copy of body_buf. }
    procedure emit_wrapper(buf: tppreproc_buf;
                           const wrapper_name: shortstring;
                           v: int64;
                           const kname: shortstring;
                           const emit_paras: array of tspecset_emit_param;
                           paras_count: longint;
                           body_buf: tppreproc_buf);
      var
        i: longint;
        first_para: boolean;
      begin
        ppreproc_emit_keyword(buf, _PROCEDURE);
        ppreproc_emit_ident(buf, wrapper_name);

        ppreproc_emit_punct(buf, _LKLAMMER);
        first_para := true;
        for i := 0 to paras_count - 1 do
          begin
            if emit_paras[i].is_specparam then
              continue;
            if not first_para then
              ppreproc_emit_punct(buf, _SEMICOLON);
            emit_param_spec(buf, emit_paras[i].spec);
            ppreproc_emit_ident(buf, emit_paras[i].name);
            ppreproc_emit_punct(buf, _COLON);
            ppreproc_emit_ident(buf, emit_paras[i].typename);
            first_para := false;
          end;
        ppreproc_emit_punct(buf, _RKLAMMER);
        ppreproc_emit_punct(buf, _SEMICOLON);

        { inline directive }
        ppreproc_emit_ident_as(buf, 'inline', _INLINE);
        ppreproc_emit_punct(buf, _SEMICOLON);

        { const k = <v>; }
        ppreproc_emit_keyword(buf, _CONST);
        ppreproc_emit_ident(buf, kname);
        ppreproc_emit_punct(buf, _EQ);
        ppreproc_emit_intliteral(buf, v);
        ppreproc_emit_punct(buf, _SEMICOLON);

        { Body tokens: local decls + begin..end. }
        copy_buf_into(buf, body_buf);

        { Trailing `;' after the body's `end'. }
        ppreproc_emit_punct(buf, _SEMICOLON);
      end;

    { Emit:
        procedure <fname>(<full sig including k in source order>); inline;
        begin
          case <kname> of
            <v1>: <fname>__K_<v1>(<args minus k in source order>);
            ...
          end;
        end;
    }
    procedure emit_dispatch_stub(buf: tppreproc_buf;
                                 const fname: shortstring;
                                 const kname: shortstring;
                                 const emit_paras: array of tspecset_emit_param;
                                 paras_count: longint;
                                 const values: array of int64);
      var
        i, j: longint;
        first_arg: boolean;
      begin
        ppreproc_emit_keyword(buf, _PROCEDURE);
        ppreproc_emit_ident(buf, fname);

        { Full signature -- preserves user's source order, K and all. }
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
        ppreproc_emit_punct(buf, _SEMICOLON);

        { inline directive }
        ppreproc_emit_ident_as(buf, 'inline', _INLINE);
        ppreproc_emit_punct(buf, _SEMICOLON);

        { begin case <kname> of ... end; end; }
        ppreproc_emit_keyword(buf, _BEGIN);
        ppreproc_emit_keyword(buf, _CASE);
        ppreproc_emit_ident(buf, kname);
        ppreproc_emit_keyword(buf, _OF);

        for i := 0 to high(values) do
          begin
            ppreproc_emit_intliteral(buf, values[i]);
            ppreproc_emit_punct(buf, _COLON);
            ppreproc_emit_ident(buf, fname + '__K_' + tostr(values[i]));
            ppreproc_emit_punct(buf, _LKLAMMER);
            first_arg := true;
            for j := 0 to paras_count - 1 do
              begin
                if emit_paras[j].is_specparam then
                  continue;
                if not first_arg then
                  ppreproc_emit_punct(buf, _COMMA);
                ppreproc_emit_ident(buf, emit_paras[j].name);
                first_arg := false;
              end;
            ppreproc_emit_punct(buf, _RKLAMMER);
            ppreproc_emit_punct(buf, _SEMICOLON);
          end;

        ppreproc_emit_keyword(buf, _END);  { case-end }
        ppreproc_emit_punct(buf, _SEMICOLON);
        ppreproc_emit_keyword(buf, _END);  { proc-end }
        ppreproc_emit_punct(buf, _SEMICOLON);
      end;

    { ============================================================
       pp_after_proc_body handler -- emit + inject
      ============================================================ }

    function pspecset_handle_after_body(ctx: pointer): boolean;
      var
        body_ctx: pppreproc_proc_body_ctx;
        pd: tprocdef;
        entry: tpspecset_proc_entry;
        param_entry: tpspecset_param_entry;
        emit_paras: array[0..63] of tspecset_emit_param;
        paras_count: longint;
        inject_buf: tppreproc_buf;
        inject_origin: tppreproc_origin;
        i: longint;
        wrapper_name: shortstring;
        kname: shortstring;
        orig_name: shortstring;
      begin
        { Initialise out-parameters defensively in case a helper bails. }
        paras_count := 0;
        fillchar(emit_paras, sizeof(emit_paras), 0);
        result := false;
        if not assigned(ctx) then
          exit;
        body_ctx := pppreproc_proc_body_ctx(ctx);
        if not (body_ctx^.procdef is tprocdef) then
          exit;
        pd := tprocdef(body_ctx^.procdef);
        entry := pspecset_find(pd);
        if entry = nil then
          exit;
        if not assigned(entry.body_buf) then
          exit;

        { Finalise body capture. }
        ppreproc_capture_end(entry.body_buf);
        Comment(V_Debug, 'specialize-set: body capture ended, ' +
          tostr(entry.body_buf.data.size) + ' bytes');

        { v1: only one specialize-set parameter supported. }
        if length(entry.params) <> 1 then
          begin
            Comment(V_Error,
              'specialize-set: multi-parameter desugar not yet supported');
            exit;
          end;
        param_entry := entry.params[0];
        kname := param_entry.param_name;
        orig_name := entry.orig_name;

        { Collect ALL visible params (in source order) from the procdef.
          The specialize-bearing one is flagged via is_specparam. }
        if not collect_visible_params(pd, kname, emit_paras, paras_count) then
          exit;

        { Build the injection buffer. The leading `;' satisfies
          read_proc_body's consume(_SEMICOLON) that fires right after
          we return -- see the matching `if current_scanner.token =
          _SEMICOLON then consume' below for the rest of the dance. }
        inject_origin.triggered_at := current_filepos;
        inject_origin.feature := 'specialize-set-emit';
        inject_buf := tppreproc_buf.create(inject_origin);
        ppreproc_emit_punct(inject_buf, _SEMICOLON);

        for i := 0 to high(param_entry.values) do
          begin
            wrapper_name := orig_name + '__K_' +
                            tostr(param_entry.values[i]);
            emit_wrapper(inject_buf, wrapper_name,
                         param_entry.values[i], kname,
                         emit_paras, paras_count, entry.body_buf);
          end;

        { The user's procsym was already renamed in SS-A; orig_name
          is now free for the dispatch stub to claim when its decl
          parses out of the inject buffer. }
        emit_dispatch_stub(inject_buf, orig_name, kname,
                           emit_paras, paras_count, param_entry.values);

        { read_proc_body (psub.pas:2912) will call consume(_SEMICOLON)
          shortly after we return -- it expects the `;' that follows
          the body's `end' in user source. Eat the user's `;' now,
          and prepend our own `;' to the inject buffer so the upcoming
          consume sees one. After the buffer drains, scanner control
          returns to user source one token past the original `;' --
          ready for the next user-level decl (e.g. `procedure g'). }
        if current_scanner.token = _SEMICOLON then
          consume(_SEMICOLON);

        Comment(V_Debug,
          'specialize-set: inject buffer ' + tostr(inject_buf.data.size) +
          ' bytes (' + tostr(length(param_entry.values)) +
          ' wrappers + 1 stub)');

        ppreproc_inject(inject_buf);

        { body_buf is no longer needed; release. The injection buffer
          stays alive until the scanner replay is done -- the scanner
          owns the underlying tdynamicarray during replay; we leak the
          tppreproc_buf wrapper. v1: trivial leak per specset proc;
          revisit if it ever matters. }
        entry.body_buf.free;
        entry.body_buf := nil;

        result := true;
      end;

initialization

    ppreproc_register(
      ppreproc_make_pass(
        'specialize-set',
        pp_at_param_modifier,
        _ID,
        _SPECIALIZE,
        @pspecset_handle_param_modifier
      )
    );
    ppreproc_register(
      ppreproc_make_pass(
        'specialize-set-before-body',
        pp_before_proc_body,
        NOTOKEN,
        NOTOKEN,
        @pspecset_handle_before_body
      )
    );
    ppreproc_register(
      ppreproc_make_pass(
        'specialize-set-after-body',
        pp_after_proc_body,
        NOTOKEN,
        NOTOKEN,
        @pspecset_handle_after_body
      )
    );

finalization

    if assigned(entries) then
      entries.free;

end.
