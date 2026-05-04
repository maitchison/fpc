{
    Specialize-set parameter modifier.

    Recognises `param: T specialize [v1, v2, .., a..b]' inside a
    parameter list. For SS-A this only PARSES + VALIDATES + STORES
    the modifier on a sidecar; the desugaring (generic-with-const-K
    + inline dispatch stub) lands in SS-B.

    Sidecar lifetime: process-global. The entry list is keyed by
    procdef pointer and lives until the compiler shuts down. Memory
    cost is trivial -- one entry per specialize-set-bearing proc.

    Hook: registers a pp_at_param_modifier pass triggered on
    `_ID/_SPECIALIZE'. The handler runs INSIDE parse_parameter_dec
    after single_type has produced the parameter type, so it has
    access to the procdef being filled, the comma-group of param
    syms just inserted, and the parsed type (via the context record
    supplied by the dispatcher).
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
        params: array of tpspecset_param_entry;
        constructor create(apd: tprocdef);
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

    { Helper: bail out of the parser cleanly after a specialize-set
      error. Skips to (and consumes) the closing `]'. Caller already
      issued the error message. }
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

    { Parse the set body `[v1, v2, .., a..b, ...]'. The opening `['
      MUST already have been consumed by the caller. Appends parsed
      values (ranges fully expanded) into `values', updating nvalues.
      Returns true on success and consumes the trailing `]'; on error
      issues a Message and returns false (with the parser advanced
      past the closing `]' so subsequent declarations parse cleanly). }
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
          { lower bound -- or sole value if no `..' follows }
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
              { duplicates within the set are pointless but not fatal;
                drop them silently to keep the cartesian count honest }
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

    { The pp_at_param_modifier handler. Triggered by `specialize'
      after a parameter type. Returns true if it consumed the
      construct; false leaves scanner state unchanged.

      Validates:
        * ctx is supplied (would be a framework bug otherwise)
        * procdef is a real tprocdef (not a procvar)
        * exactly one parameter sym in the comma group
        * parameter type is ordinal
        * set body parses cleanly
        * total cardinality across all this proc's specialize-set
          params <= PSPECSET_MAX_VALUES

      On success stores a tpspecset_param_entry on the per-procdef
      sidecar and emits a -vd diagnostic. SS-A does NOT emit any
      desugar -- the caller-side parser keeps treating the parameter
      as a plain `T'. The desugar lands in SS-B via the
      pp_after_proc_body hook reading the sidecar. }
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

        { Confirm the dispatch trigger -- defensive; the framework
          already filtered, but we want to abort cleanly if not. }
        if not ((current_scanner.token = _ID) and
                (current_scanner.idtoken = _SPECIALIZE)) then
          exit;

        if not assigned(ctx) then
          exit;
        param_ctx := pppreproc_param_modifier_ctx(ctx);

        { specialize-set on a procvar parameter list is meaningless
          (procvars don't have generic instantiation). Reject. }
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

        { Restrict v1 to one parameter per modifier -- comma-group
          like `(a, b: integer specialize [...])' would mean both
          `a' and `b' are independently specialise-set, which blows
          up the cartesian fast and the user can write them one at
          a time anyway. }
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

        { Look up the existing sidecar to know the running cartesian
          count -- the per-modifier cap interacts with prior modifiers
          on the same proc. }
        entry := pspecset_find(pd);
        if entry = nil then
          existing_count := 1
        else
          existing_count := pspecset_total_count(entry);

        setlength(values, PSPECSET_MAX_VALUES);
        nvalues := 0;
        if not parse_set_body(values, nvalues, PSPECSET_MAX_VALUES) then
          begin
            { parse_set_body already issued the Message and recovered }
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

        { Commit to the sidecar. }
        entry := pspecset_get_or_create(pd);
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

finalization

    if assigned(entries) then
      entries.free;

end.
