{
    Token-level preprocessor framework for FPC sugar features.

    Lets a feature register a "pass" that fires at a known grammar
    point in the parser (e.g. just after a parameter type was parsed),
    captures some tokens from the user's source, transforms them, and
    injects the result back into the scanner so the parser reads the
    rewritten form as if the user had written it.

    Built on top of the existing `startrecordtokens` / `startreplaytokens`
    machinery in scanner.pas (originally added for cross-unit generic
    body replay). This unit exposes that machinery as a stable API
    for sugar features.

    Design notes:
      * Token-based, not string-based and not AST-based -- see
        new_inline.txt / project notes for rationale.
      * Per-grammar-point dispatch (option `(a)' from the design discussion).
        The parser calls ppreproc_try_dispatch(<point>) at well-defined
        spots; each registered pass declares which point(s) it fires at.
      * Hybrid position model: each token carries the user-source
        position it was derived from (default for error messages); each
        injected buffer also carries an "origin trail" recording where
        the expansion came from, so the error printer can append
        "(in expansion of <feature> at <pos>)".
      * Single-pass per trigger -- the framework never re-runs a pass
        on its own emitted tokens. If two features want to compose,
        they register at different grammar points or call each other
        explicitly.
      * Lazy capture: handlers should peek for their trigger token
        BEFORE starting capture, so procs that don't use any sugar pay
        only one comparison per grammar point.

    Public surface:

      ppreproc_register(pass)        -- register a pass.
      ppreproc_try_dispatch(point)   -- parser calls this at a hook
                                        point; returns TRUE if a pass
                                        consumed the construct.

      ppreproc_capture_begin         -- start recording scanner tokens
                                        into a fresh buffer.
      ppreproc_capture_end(b)        -- stop recording.

      ppreproc_clone(src)            -- duplicate a buffer.
      ppreproc_rename_ident(b, a, c) -- replace identifier text "a"
                                        with "c" everywhere in b.
      ppreproc_inject(b)             -- push b onto the scanner so the
                                        parser reads it next.

    Limitations (v1):
      * Only ONE record buffer can be active at a time (scanner-level
        constraint -- internalerror 200511173). Passes must not start
        a capture while another is in progress; ppreproc_capture_begin
        asserts this.
      * Synthesising tokens that didn't come from real source (e.g.
        a fabricated `case k of ...' body) requires writing tokens
        directly via the scanner's tokenwrite primitives. That's done
        by feature-specific code today; a generic "synth from string"
        helper is a future addition.
      * The error printer doesn't yet read the origin trail. Position
        carrying is wired through the buffer; surfacing it in errors
        is a follow-up.
}
unit ppreproc;

{$i fpcdefs.inc}

interface

    uses
      cclasses,
      globtype,
      tokens;

    type
      { Grammar points where the parser calls ppreproc_try_dispatch.
        Add new points as features need them. Keep this list small --
        each point is a constant overhead per parse. }
      tppreproc_point = (
        { Just after a parameter type was parsed in a parameter list.
          Scanner state: type fully consumed; next token is whatever
          follows the type (modifier keyword, `;', `)', `=' for default).
          Used by feature/dynamic-params for `T specialize [set]'. }
        pp_at_param_modifier,
        { Just before block() parses a procedure/function body. The
          procdef's parameter list is finalised (parast filled in,
          calling-convention applied). Scanner is at whatever begins
          the body region: either the first local-decl keyword
          (`var', `const', `type', `procedure', ...) or `begin' if
          there are no local decls. Hooking here is the right spot to
          start a body-capture buffer that should include local decls
          + statement block.
          Uses tppreproc_proc_body_ctx (same record as pp_after_proc_body). }
        pp_before_proc_body,
        { Just after a procedure/function body has been parsed and the
          procdef is fully populated (procdef.is_implemented = true).
          Scanner state: at whatever follows the proc's terminating
          `end;' -- typically the next top-level decl or implementation
          item. The procdef's symbol tables are still on the stack;
          generictokenbuf (if recorded) is fully captured and owned
          by the procdef.
          Used by feature/dynamic-params and feature/codegen-proc for
          post-body lowering (generate companion declarations, etc.). }
        pp_after_proc_body
      );

      { Origin record describing where a synthetic buffer came from. }
      tppreproc_origin = record
        { Position in user source where the expansion was triggered.
          E.g. for a `specialize [set]' modifier, this is the position
          of the `specialize' keyword. }
        triggered_at: tfileposinfo;
        { Short feature tag for error messages: "specialize-set",
          "memoized", etc. }
        feature: ansistring;
      end;

      { A captured-or-synthetic token buffer, plus its origin trail.
        Wraps tdynamicarray (the underlying scanner buffer) so we can
        attach metadata without touching scanner internals. }
      tppreproc_buf = class
      public
        { the actual token bytes; format matches scanner's recordtoken/
          replaytoken serialisation }
        data: tdynamicarray;
        { where this buffer originated -- used for "expanded from"
          annotations on error messages (wiring TBD) }
        origin: tppreproc_origin;
        constructor create(const aorigin: tppreproc_origin);
        destructor destroy; override;
      end;

      { Context payload for pp_at_param_modifier. The procdef is the
        proc whose parameter list is being parsed; param_syms is a
        TFPObjectList of tparavarsym just inserted for the current
        comma-group (e.g. for `a, b: integer specialize [...]', list
        is [a-sym, b-sym]); param_type is the tdef returned from
        single_type. All fields are tobject because ppreproc.pas does
        not depend on symdef/symsym -- consumers cast on use. }
      tppreproc_param_modifier_ctx = record
        procdef: tobject;
        param_syms: tobject;
        param_type: tobject;
      end;
      pppreproc_param_modifier_ctx = ^tppreproc_param_modifier_ctx;

      { Context payload for pp_after_proc_body. procdef is fully
        populated; if it was generic, procdef.generictokenbuf holds
        the captured body. }
      tppreproc_proc_body_ctx = record
        procdef: tobject;
      end;
      pppreproc_proc_body_ctx = ^tppreproc_proc_body_ctx;

      { Handler signature for a registered pass. The handler is invoked
        when the parser hits the grammar point and the trigger token
        matches the next scanner token. `ctx` carries point-specific
        parser state -- see the tppreproc_*_ctx records above. May be
        nil at points that don't supply context. Returns TRUE if the
        construct was consumed (parser should not try further passes);
        FALSE to leave scanner state unchanged. }
      tppreproc_handler = function(ctx: pointer): boolean;

      tppreproc_pass = record
        { stable feature tag; appears in -vd diagnostics }
        name: ansistring;
        { which grammar point this pass fires at }
        point: tppreproc_point;
        { the token that triggers this pass. The framework checks
          current_scanner.token against this BEFORE invoking the
          handler, so handlers don't pay for failed peeks. Set to
          NOTOKEN to match any token at this point (rare; usually
          a feature is keyed on a specific keyword). }
        trigger: ttoken;
        { idtoken to also match against (since FPC keywords often
          arrive as token=_ID, idtoken=<keyword>). Set to NOTOKEN
          to ignore. If both trigger and trigger_id are NOTOKEN,
          the pass fires unconditionally at this grammar point. }
        trigger_id: ttoken;
        { the handler procedure }
        handler: tppreproc_handler;
      end;

    { ---- registration ---- }

    procedure ppreproc_register(const pass: tppreproc_pass);
    function  ppreproc_try_dispatch(point: tppreproc_point; ctx: pointer = nil): boolean;

    { Convenience: build a tppreproc_pass record without a verbose call
      site. }
    function ppreproc_make_pass(const aname: ansistring;
                                apoint: tppreproc_point;
                                atrigger, atrigger_id: ttoken;
                                ahandler: tppreproc_handler): tppreproc_pass;

    { ---- capture ---- }

    function  ppreproc_capture_begin(const aorigin: tppreproc_origin): tppreproc_buf;
    procedure ppreproc_capture_end(b: tppreproc_buf);

    { ---- transform (read/write helpers; expanded in PP-3) ---- }

    function  ppreproc_clone(src: tppreproc_buf): tppreproc_buf;

    { ---- synthesise tokens directly into a buffer ----

      These helpers append individual tokens to a buffer without going
      through the scanner. They write the same wire format that
      tscannerfile.recordtoken produces, so the buffer can be replayed
      with ppreproc_inject and the parser will see the synthesised
      tokens as if the user had written them.

      No position markers are emitted -- replay leaves current_tokenpos
      at whatever it was when injection started. If you need synthesised
      tokens to report at a specific user-source position, set
      current_filepos before injecting; the parser will see that as the
      position of every synthesised token until the buffer is exhausted.

      Settings markers are also not emitted -- replay uses the scanner's
      current_settings at injection time. Don't synthesise tokens that
      depend on a different mode-switch state than the surrounding
      source. }

    { Append a punctuation/operator token (`:', `;', `(', `<', etc.).
      Sets idtoken=_NOID, matching the scanner's behaviour for non-
      identifier characters. }
    procedure ppreproc_emit_punct(buf: tppreproc_buf; t: ttoken);

    { Append a keyword token (`begin', `case', `of', `end', ...).
      Sets idtoken=token, matching the scanner's behaviour when an
      identifier text matches a reserved word in the active mode. }
    procedure ppreproc_emit_keyword(buf: tppreproc_buf; t: ttoken);

    { Append a regular identifier (token=_ID, idtoken=_ID). The name
      is stored as-is in orgpattern; replay will set pattern :=
      upper(orgpattern). }
    procedure ppreproc_emit_ident(buf: tppreproc_buf; const name: ansistring);

    { Append an identifier whose idtoken is a contextual keyword
      (e.g. `specialize' arrives as token=_ID, idtoken=_SPECIALIZE).
      Use this when the parser checks idtoken to recognise the word. }
    procedure ppreproc_emit_ident_as(buf: tppreproc_buf;
                                     const name: ansistring;
                                     contextual_idtoken: ttoken);

    { Append an integer literal token (token=_INTCONST, idtoken=_NOID).
      The value is serialised as its decimal string representation,
      matching what the scanner stores in `pattern' for _INTCONST. }
    procedure ppreproc_emit_intliteral(buf: tppreproc_buf; n: int64);

    { ---- inject ---- }

    procedure ppreproc_inject(b: tppreproc_buf);

    { ---- introspection ---- }

    { Number of currently registered passes. Useful for diagnostics. }
    function  ppreproc_pass_count: longint;
    { Iterate registered passes (caller-friendly). Returns @nil after
      the last pass. }
    function  ppreproc_pass_at(idx: longint): tppreproc_pass;


implementation

    uses
      cutils,
      verbose,
      globals,
      scanner,
      pbase;

    var
      { Master list of registered passes. Built up during compiler
        initialisation by feature units; not modified after first
        compile. }
      passes: array of tppreproc_pass;

    { -------------- tppreproc_buf -------------- }

    constructor tppreproc_buf.create(const aorigin: tppreproc_origin);
      begin
        inherited create;
        data := tdynamicarray.create(64);
        origin := aorigin;
      end;

    destructor tppreproc_buf.destroy;
      begin
        data.free;
        inherited destroy;
      end;

    { -------------- registration -------------- }

    function ppreproc_make_pass(const aname: ansistring;
                                apoint: tppreproc_point;
                                atrigger, atrigger_id: ttoken;
                                ahandler: tppreproc_handler): tppreproc_pass;
      begin
        result.name       := aname;
        result.point      := apoint;
        result.trigger    := atrigger;
        result.trigger_id := atrigger_id;
        result.handler    := ahandler;
      end;

    procedure ppreproc_register(const pass: tppreproc_pass);
      var
        n: longint;
      begin
        n := length(passes);
        setlength(passes, n+1);
        passes[n] := pass;
      end;

    function ppreproc_pass_count: longint;
      begin
        result := length(passes);
      end;

    function ppreproc_pass_at(idx: longint): tppreproc_pass;
      begin
        result := passes[idx];
      end;

    { Invoked by the parser at a grammar hook point. Walks the
      registered passes for this point; for each, checks whether
      the current scanner token matches the pass's trigger; if so,
      invokes the handler. Returns TRUE as soon as a handler reports
      that it consumed the construct. }
    function ppreproc_try_dispatch(point: tppreproc_point; ctx: pointer = nil): boolean;
      var
        i: longint;
        p: tppreproc_pass;
        match: boolean;
      begin
        result := false;
        for i := 0 to high(passes) do
          begin
            p := passes[i];
            if p.point <> point then
              continue;
            { Check trigger. The parser caller doesn't peek; we do.
              Both trigger and trigger_id default to NOTOKEN meaning
              "don't filter on this field". A non-NOTOKEN value must
              match the scanner state. }
            match := true;
            if p.trigger <> NOTOKEN then
              if current_scanner.token <> p.trigger then
                match := false;
            if match and (p.trigger_id <> NOTOKEN) then
              if current_scanner.idtoken <> p.trigger_id then
                match := false;
            if not match then
              continue;
            { Handler fires. It is responsible for consuming the
              triggering token (and any tokens after) via the normal
              consume() path, OR for capturing+injecting via the
              framework helpers. }
            if assigned(p.handler) then
              if p.handler(ctx) then
                begin
                  result := true;
                  exit;
                end;
          end;
      end;

    { -------------- capture -------------- }

    function ppreproc_capture_begin(const aorigin: tppreproc_origin): tppreproc_buf;
      begin
        { Scanner constraint: only one record buffer at a time. Any
          attempt to nest captures triggers internalerror 200511173 in
          startrecordtokens. We assert here so the diagnostic blames
          the right layer. }
        if current_scanner.is_recording_tokens then
          internalerror(2026050401);
        result := tppreproc_buf.create(aorigin);
        current_scanner.startrecordtokens(result.data);
      end;

    procedure ppreproc_capture_end(b: tppreproc_buf);
      begin
        if not assigned(b) then
          internalerror(2026050402);
        if not current_scanner.is_recording_tokens then
          internalerror(2026050403);
        current_scanner.stoprecordtokens;
      end;

    { -------------- transform (PP-3 expands) -------------- }

    function ppreproc_clone(src: tppreproc_buf): tppreproc_buf;
      var
        savepos: longword;
        b: byte;
      begin
        if not assigned(src) then
          internalerror(2026050404);
        result := tppreproc_buf.create(src.origin);
        savepos := src.data.pos;
        src.data.seek(0);
        while src.data.pos < src.data.size do
          begin
            src.data.read(b, 1);
            result.data.write(b, 1);
          end;
        src.data.seek(savepos);
      end;

    { -------------- emit helpers -------------- }

    { Write a single ttoken to a dynamic array using scanner.pas's
      packed wire format: tokens with ord <= $7f take 1 byte;
      tokens > $7f take 2 bytes (high byte with $80 set, then low). }
    procedure write_token_raw(d: tdynamicarray; t: ttoken);
      var
        b: byte;
      begin
        if ord(t) > $7f then
          begin
            b := (ord(t) shr 8) or $80;
            d.write(b, 1);
          end;
        b := ord(t) and $ff;
        d.write(b, 1);
      end;

    { Append a shortstring's length byte + payload (matches the format
      recordtoken uses for _ID orgpattern and _INTCONST pattern). }
    procedure write_shortstring_raw(d: tdynamicarray; const s: shortstring);
      var
        len: byte;
      begin
        len := length(s);
        d.write(len, 1);
        if len > 0 then
          d.write(s[1], len);
      end;

    procedure ppreproc_emit_punct(buf: tppreproc_buf; t: ttoken);
      begin
        if not assigned(buf) then
          internalerror(2026050410);
        write_token_raw(buf.data, t);
        write_token_raw(buf.data, _NOID);
      end;

    procedure ppreproc_emit_keyword(buf: tppreproc_buf; t: ttoken);
      begin
        if not assigned(buf) then
          internalerror(2026050411);
        write_token_raw(buf.data, t);
        write_token_raw(buf.data, t);
      end;

    procedure ppreproc_emit_ident(buf: tppreproc_buf; const name: ansistring);
      var
        s: shortstring;
      begin
        if not assigned(buf) then
          internalerror(2026050412);
        if length(name) > 255 then
          internalerror(2026050413);
        s := name;
        write_token_raw(buf.data, _ID);
        write_token_raw(buf.data, _ID);
        write_shortstring_raw(buf.data, s);
      end;

    procedure ppreproc_emit_ident_as(buf: tppreproc_buf;
                                     const name: ansistring;
                                     contextual_idtoken: ttoken);
      var
        s: shortstring;
      begin
        if not assigned(buf) then
          internalerror(2026050414);
        if length(name) > 255 then
          internalerror(2026050415);
        s := name;
        write_token_raw(buf.data, _ID);
        write_token_raw(buf.data, contextual_idtoken);
        write_shortstring_raw(buf.data, s);
      end;

    procedure ppreproc_emit_intliteral(buf: tppreproc_buf; n: int64);
      var
        s: shortstring;
      begin
        if not assigned(buf) then
          internalerror(2026050416);
        str(n, s);
        write_token_raw(buf.data, _INTCONST);
        write_token_raw(buf.data, _NOID);
        write_shortstring_raw(buf.data, s);
      end;

    { -------------- inject -------------- }

    procedure ppreproc_inject(b: tppreproc_buf);
      begin
        if not assigned(b) then
          internalerror(2026050405);
        { startreplaytokens saves current scanner state, installs the
          buffer as replaytokenbuf, seeks to 0, and reads the first
          token. When the buffer is exhausted the scanner pops back to
          the user's source automatically. }
        current_scanner.startreplaytokens(b.data, false);
      end;


end.
