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
      pp_before_proc_body   -- begin_specset_body_capture (body source-text capture)
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
        { Body source-text, populated by pp_after_proc_body from the
          scanner's body_capture_buf. Empty unless a capture is in
          flight or has been finalised. body_capture_active is set
          while the capture is live (pp_before_proc_body to
          pp_after_proc_body) so the after-body handler can tell
          "no capture started" from "capture finished, text empty". }
        body_text: ansistring;
        body_capture_active: boolean;
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

    { True if `pi' is currently parsing a procdef that has a registered
      specialize-set sidecar AND `paraname' matches one of its
      specialize-set params. Used by the asm reader's %if evaluator to
      treat references to such params as placeholder 0 during the
      original-body capture (the real value materialises as a
      wrapper-local const when the body is replayed per specialisation).
      `pi' is `tobject' so the asm reader's `tprocinfo' fits without
      forcing an extra unit dependency on the caller side. }
    function pspecset_is_capture_para(pi: tobject; const paraname: shortstring): boolean;

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
      procinfo,
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
        body_text := '';
        body_capture_active := false;
      end;

    destructor tpspecset_proc_entry.destroy;
      begin
        body_text := '';
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

    { Remove and free the entry. Called at end of pspecset_handle_after_body
      so the entry doesn't outlive its procdef -- once the wrappers + stub
      have been emitted there's nothing more to do for that proc, and the
      backing procdef may be freed (or its memory reused) by the time the
      next module compiles. Without this, a later procdef whose pointer
      happens to match the freed one's address would be misidentified as
      a specset proc and trigger spurious wrapper emission. }
    procedure pspecset_remove(entry: tpspecset_proc_entry);
      var
        idx: longint;
      begin
        if (entry = nil) or (not assigned(entries)) then
          exit;
        idx := entries.IndexOf(entry);
        if idx >= 0 then
          entries.Delete(idx);
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

    function pspecset_is_capture_para(pi: tobject; const paraname: shortstring): boolean;
      var
        entry: tpspecset_proc_entry;
        pd: tprocdef;
        i: longint;
      begin
        result := false;
        if not assigned(pi) then
          exit;
        if not (pi is tprocinfo) then
          exit;
        pd := tprocinfo(pi).procdef;
        if not assigned(pd) then
          exit;
        entry := pspecset_find(pd);
        if entry = nil then
          exit;
        for i := 0 to high(entry.params) do
          if SameText(entry.params[i].param_name, paraname) then
            begin
              result := true;
              exit;
            end;
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

        entry := pspecset_find(pd);
        if entry = nil then
          existing_count := 1
        else
          existing_count := pspecset_total_count(entry);

        setlength(values, PSPECSET_MAX_VALUES);
        nvalues := 0;

        if current_scanner.token <> _LECKKLAMMER then
          begin
            { Boolean shortcut: `x: boolean specialize' (no bracket list)
              auto-fills [false, true]. Only ordinal types whose full
              value space is exactly two values qualify; non-boolean
              ordinals still require an explicit set. }
            if is_boolean(hdef) then
              begin
                values[0] := 0;
                values[1] := 1;
                nvalues := 2;
              end
            else
              begin
                Comment(V_Error,
                  'specialize-set: `['' expected');
                result := true;
                exit;
              end;
          end
        else
          begin
            consume(_LECKKLAMMER);
            if not parse_set_body(values, nvalues, PSPECSET_MAX_VALUES) then
              begin
                result := true;
                exit;
              end;
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
        if entry.body_capture_active then
          { defensive: capture already in progress for this procdef }
          exit;
        if current_scanner.is_recording_tokens then
          begin
            { conflict with FPC's generic-body capture; not supported in v1 }
            Comment(V_Error,
              'specialize-set: cannot combine with a generic procedure');
            exit;
          end;

        { Char-level body capture. Sidesteps the recordtoken/replaytoken
          metadata-replay path that leaks pendingstate.nextmessagerecord
          across module boundaries (the SS-B token-stream approach used
          to do `startrecordtokens(buf)' here). The captured text is
          re-tokenised at wrapper-emit time via substitutemacro, so each
          per-value wrapper gets a fresh parse under the surrounding
          module's current settings. }
        current_scanner.begin_specset_body_capture;
        entry.body_capture_active := true;
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
        { The parameter's declared type. Used by emit_default_for_param
          to format the default literal (boolean keywords vs. ordinal
          digits). nil only if the param had no usable typesym, but
          collect_visible_params errors out before reaching that case. }
        param_def: tdef;
        { The parameter's default-value sym (`= <expr>' in source), or
          nil if none. Re-emitted into the dispatch stub's signature so
          callers can omit the optional argument; wrappers don't carry
          defaults (the stub always passes args explicitly). }
        default_constsym: tsym;
      end;

    { Format a single value as a Pascal source literal of the right
      textual form for the param def: `false'/`true' for booleans, the
      enum element's identifier for enums, the decimal representation
      for everything else. The wrapper text is pushed through
      substitutemacro and re-tokenised in the wrapper's scope, so
      untyped 0 would not match a boolean or enum param's `case' arm. }
    function value_literal_text(v: int64; param_def: tdef): ansistring;
      var
        esym: tsym;
      begin
        if assigned(param_def) and is_boolean(param_def) then
          begin
            if v = 0 then
              result := 'false'
            else
              result := 'true';
            exit;
          end;
        if assigned(param_def) and is_enum(param_def) then
          begin
            esym := tenumdef(param_def).int2enumsym(v);
            if assigned(esym) then
              begin
                result := esym.realname;
                exit;
              end;
            { Out-of-range value somehow slipped past parse-time
              checking; fall through to integer emit so the caller
              still sees a syntactically-valid literal. The case-arm
              type-mismatch will surface as a clear compile error. }
          end;
        result := tostr(v);
      end;

    function param_spec_text(spec: tvarspez): ansistring;
      begin
        case spec of
          vs_var:      result := 'var ';
          vs_const:    result := 'const ';
          vs_out:      result := 'out ';
          vs_constref: result := 'constref ';
          else
            result := '';
        end;
      end;

    function default_for_param_text(ds: tsym; param_def: tdef): ansistring;
      var
        cs: tconstsym;
      begin
        result := '';
        if not assigned(ds) then
          exit;
        if ds.typ <> constsym then
          exit;
        cs := tconstsym(ds);
        if cs.consttyp <> constord then
          exit;
        result := ' = ' + value_literal_text(int64(cs.value.valueord), param_def);
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
            emit_paras[count].param_def := ps.vardef;
            emit_paras[count].default_constsym := ps.defaultconstsym;
            inc(count);
          end;
      end;

    { Build:
        procedure <wrapper_name>(<sig minus k>); inline;
        const <kname> = <v>;
        <body_text>
        ;
      as a Pascal source string. body_text is the captured body source
      verbatim (including the leading `begin'/`var'/etc. and the closing
      `end'); the trailing `;' after `end' is appended here. }
    function build_wrapper_text(const wrapper_name: shortstring;
                                v: int64;
                                const kname: shortstring;
                                const emit_paras: array of tspecset_emit_param;
                                paras_count: longint;
                                const body_text: ansistring;
                                param_def: tdef;
                                emit_inline: boolean): ansistring;
      var
        i: longint;
        first_para: boolean;
      begin
        result := 'procedure ' + wrapper_name + '(';
        first_para := true;
        for i := 0 to paras_count - 1 do
          begin
            if emit_paras[i].is_specparam then
              continue;
            if not first_para then
              result := result + '; ';
            result := result + param_spec_text(emit_paras[i].spec) +
                      emit_paras[i].name + ': ' + emit_paras[i].typename;
            first_para := false;
          end;
        result := result + '); ';

        { Inherit `inline;' from the source proc only. The dispatch stub is
          always inline (that's what folds constant call sites); the wrapper
          body might not be a candidate for inlining at all -- e.g. when the
          source proc is `procedure foo(...); asm ... end;' or has any other
          construct that triggers `pio_inline_not_possible'. Forcing inline
          on every wrapper trips parser_n_not_supported_for_inline notes for
          asm bodies and worse, leaves the asm reader / parser in a bad
          state for subsequent declarations. }
        if emit_inline then
          result := result + 'inline; ';

        { const k = <v>; -- value form depends on the param's type so
          that boolean specialisations emit `const k = false;' instead
          of `const k = 0;' (untyped 0 would not match boolean uses). }
        result := result + 'const ' + kname + ' = ' +
                  value_literal_text(v, param_def) + ';' + #10;

        { Body source: local decls + begin..end. Followed by the `;'
          read_proc_body's caller expects after each proc decl. }
        result := result + body_text + ';' + #10;
      end;

    { Build:
        procedure <fname>(<full sig including k in source order>); inline;
        begin
          case <kname> of
            <v1>: <fname>__K_<v1>(<args minus k in source order>);
            ...
          end;
        end;
    }
    function build_dispatch_stub_text(const fname: shortstring;
                                      const kname: shortstring;
                                      const emit_paras: array of tspecset_emit_param;
                                      paras_count: longint;
                                      const values: array of int64;
                                      param_def: tdef): ansistring;
      var
        i, j: longint;
        first_arg: boolean;
      begin
        result := 'procedure ' + fname + '(';

        { Full signature -- preserves user's source order, K and all,
          including any `= <default>' the user wrote. Without the
          default re-emitted, callers omitting the optional arg would
          fail with parser_e_wrong_parameter_size against the stub. }
        for i := 0 to paras_count - 1 do
          begin
            if i > 0 then
              result := result + '; ';
            result := result + param_spec_text(emit_paras[i].spec) +
                      emit_paras[i].name + ': ' + emit_paras[i].typename +
                      default_for_param_text(emit_paras[i].default_constsym,
                                             emit_paras[i].param_def);
          end;
        result := result + '); inline;' + #10 +
                  'begin case ' + kname + ' of' + #10;

        for i := 0 to high(values) do
          begin
            result := result + '  ' + value_literal_text(values[i], param_def) +
                      ': ' + fname + '__K_' + tostr(values[i]) + '(';
            first_arg := true;
            for j := 0 to paras_count - 1 do
              begin
                if emit_paras[j].is_specparam then
                  continue;
                if not first_arg then
                  result := result + ', ';
                result := result + emit_paras[j].name;
                first_arg := false;
              end;
            result := result + ');' + #10;
          end;

        result := result + 'end;' + #10 + 'end;' + #10;
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
        synth_text: ansistring;
        synth_origin: tfileposinfo;
        i, j: longint;
        wrapper_name: shortstring;
        kname: shortstring;
        orig_name: shortstring;
        spec_default: tsym;
        spec_default_v: int64;
        spec_default_in_set: boolean;
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
        if not entry.body_capture_active then
          exit;

        { Finalise body capture. The text is trimmed at the body's outer
          `end' via the body_capture_endmark snapshot taken in pbase
          consume(_END). }
        entry.body_text := current_scanner.end_specset_body_capture;
        entry.body_capture_active := false;
        Comment(V_Debug, 'specialize-set: body capture ended, ' +
          tostr(length(entry.body_text)) + ' bytes');

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

        { Validate any default on the spec-set parameter is itself a
          member of the set. A default outside the set would be uncatchable
          at runtime -- the dispatch case has no `else' arm -- and silently
          fall through. Other params' defaults are typechecked by the
          parser at declaration time, so they don't need re-validation. }
        spec_default := nil;
        for i := 0 to paras_count - 1 do
          if emit_paras[i].is_specparam then
            begin
              spec_default := emit_paras[i].default_constsym;
              break;
            end;
        if assigned(spec_default) then
          begin
            if (spec_default.typ <> constsym) or
               (tconstsym(spec_default).consttyp <> constord) then
              begin
                Comment(V_Error,
                  'specialize-set: parameter "' + kname +
                  '" default must be an ordinal constant');
                exit;
              end;
            spec_default_v := int64(tconstsym(spec_default).value.valueord);
            spec_default_in_set := false;
            for j := 0 to high(param_entry.values) do
              if param_entry.values[j] = spec_default_v then
                begin
                  spec_default_in_set := true;
                  break;
                end;
            if not spec_default_in_set then
              begin
                Comment(V_Error,
                  'specialize-set: parameter "' + kname +
                  '" default value ' + tostr(spec_default_v) +
                  ' is not in the set');
                exit;
              end;
          end;

        { Build the synthetic source: N wrappers + 1 dispatch stub. The
          user's `;' that follows the body's `end' has already been
          tokenised into current_scanner.token by the time we run, so we
          DON'T consume it: we let it stay there for read_proc_body's
          consume(_SEMICOLON) (psub.pas:2965), which fires right after we
          return. substitutemacro changes the input file but leaves
          current_scanner.token alone, so the pending _SEMICOLON survives
          the input switch. After consume(_SEMICOLON), the parser advances
          into the synthetic and reads our first wrapper's `procedure ...'
          token. When the synthetic drains, scanner control returns to
          user source one token past the original `;' -- ready for the
          next user-level decl (e.g. `procedure g'). }
        synth_text := '';
        for i := 0 to high(param_entry.values) do
          begin
            wrapper_name := orig_name + '__K_' +
                            tostr(param_entry.values[i]);
            synth_text := synth_text +
              build_wrapper_text(wrapper_name,
                                 param_entry.values[i], kname,
                                 emit_paras, paras_count, entry.body_text,
                                 param_entry.param_def,
                                 { Only emit `inline;' on the wrapper if the user's
                                   source proc was declared inline. Asm-bodied procs
                                   and other inline-incompatible constructs aren't
                                   tagged inline by the user, so the wrapper stays
                                   a regular call. }
                                 po_inline in pd.procoptions);
          end;

        { The user's procsym was already renamed in SS-A; orig_name
          is now free for the dispatch stub to claim when its decl
          parses out of the synthetic source. }
        synth_text := synth_text +
          build_dispatch_stub_text(orig_name, kname,
                                   emit_paras, paras_count, param_entry.values,
                                   param_entry.param_def);

        Comment(V_Debug,
          'specialize-set: synthetic source ' + tostr(length(synth_text)) +
          ' bytes (' + tostr(length(param_entry.values)) +
          ' wrappers + 1 stub)');

        { Push the wrapper+stub source as a synthetic input file. The
          parser re-tokenises from scratch under the surrounding module's
          current settings -- no replaytoken, no metadata-replay path,
          no pendingstate.nextmessagerecord leak. }
        synth_origin := current_filepos;
        current_scanner.substitutemacro('specset_body',
          @synth_text[1], length(synth_text),
          synth_origin.line, synth_origin.fileindex, true);

        { body_text is no longer needed; release. }
        entry.body_text := '';

        { Remove the entry. The procdef this entry pinned may be freed
          when its module unloads, and a future procdef can be allocated
          at the same address; without removing the entry we'd incorrectly
          treat that future procdef as a specset proc. }
        pspecset_remove(entry);

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
