"""Patch computer use platform gates to accept Linux."""

import re


def apply(content):
    """
    Remove darwin-only guards from computer use TCC and feature checks.

    The app has an object (FWn) with methods like getState(), requestAccessibility(),
    requestScreenRecording() that all short-circuit with 'not-supported' when
    process.platform !== 'darwin'. On Linux, we route these through our own
    TCC-equivalent permission system via the computerUse namespace on claude-swift.
    """
    total_patched = 0

    # Pattern 1: TCC getState() darwin guard
    #   if(process.platform!=="darwin")return{accessibility:ID.NotSupported,screenRecording:ID.NotSupported}
    # This appears inside the getState() method of the TCC implementation object.
    pattern_state = (
        r'if\(process\.platform!=="darwin"\)'
        r'return\{accessibility:(\w+)\.NotSupported,screenRecording:\1\.NotSupported\}'
    )
    for match in reversed(list(re.finditer(pattern_state, content))):
        id_var = match.group(1)
        # Replace: on linux, don't short-circuit — fall through to the swift computerUse.tcc check
        replacement = (
            f'if(process.platform!=="darwin"&&process.platform!=="linux")'
            f'return{{accessibility:{id_var}.NotSupported,screenRecording:{id_var}.NotSupported}}'
        )
        content = content[:match.start()] + replacement + content[match.end():]
        total_patched += 1
        print(f'  [found] TCC getState() darwin guard')

    # Pattern 2: TCC request methods darwin guard
    #   if(process.platform!=="darwin")return ID.NotSupported
    # Appears in requestAccessibility() and requestScreenRecording()
    pattern_request = (
        r'if\(process\.platform!=="darwin"\)'
        r'return (\w+)\.NotSupported'
    )
    for match in reversed(list(re.finditer(pattern_request, content))):
        id_var = match.group(1)
        replacement = (
            f'if(process.platform!=="darwin"&&process.platform!=="linux")'
            f'return {id_var}.NotSupported'
        )
        content = content[:match.start()] + replacement + content[match.end():]
        total_patched += 1
        print(f'  [found] TCC request method darwin guard')

    # Pattern 3: listInstalledApps darwin guard
    #   process.platform!=="darwin"?[]:...
    pattern_list = r'process\.platform!=="darwin"\?\[\]:'
    for match in reversed(list(re.finditer(pattern_list, content))):
        replacement = '(process.platform!=="darwin"&&process.platform!=="linux")?[]:'
        content = content[:match.start()] + replacement + content[match.end():]
        total_patched += 1
        print(f'  [found] listInstalledApps darwin guard')

    # Pattern 4: hasComputerUse gate — o7()
    #   function X(){return process.platform==="darwin"&&Y()&&Ur("chicagoEnabled")}
    # This determines whether computer use tools are offered to the model.
    pattern_has_cu = (
        r'function\s+([\w$]+)\(\)\{'
        r'return process\.platform==="darwin"&&([\w$]+)\(\)&&([\w$]+)\("chicagoEnabled"\)'
        r'\}'
    )
    for match in reversed(list(re.finditer(pattern_has_cu, content))):
        func_name = match.group(1)
        yn_func = match.group(2)
        ur_func = match.group(3)
        print(f'  [found] hasComputerUse gate: {func_name}()')
        replacement = (
            f'function {func_name}()'
            f'{{return(process.platform==="darwin"||process.platform==="linux")'
            f'&&{yn_func}()&&{ur_func}("chicagoEnabled")}}'
        )
        content = content[:match.start()] + replacement + content[match.end():]
        total_patched += 1

    # Pattern 5: computerUseAvailableButOptedOut — ion()
    #   function X(){return process.platform==="darwin"&&Y()&&!Ur("chicagoEnabled")}
    pattern_opted_out = (
        r'function\s+([\w$]+)\(\)\{'
        r'return process\.platform==="darwin"&&([\w$]+)\(\)&&!([\w$]+)\("chicagoEnabled"\)'
        r'\}'
    )
    for match in reversed(list(re.finditer(pattern_opted_out, content))):
        func_name = match.group(1)
        yn_func = match.group(2)
        ur_func = match.group(3)
        print(f'  [found] computerUseAvailableButOptedOut gate: {func_name}()')
        replacement = (
            f'function {func_name}()'
            f'{{return(process.platform==="darwin"||process.platform==="linux")'
            f'&&{yn_func}()&&!{ur_func}("chicagoEnabled")}}'
        )
        content = content[:match.start()] + replacement + content[match.end():]
        total_patched += 1

    # Pattern 6: HFt capabilities platform constant
    #   {screenshotFiltering:"native",platform:"darwin"}
    # This is passed to the computer use tool builder. On Linux we keep
    # screenshotFiltering:"native" but change platform to "linux".
    old_cap = 'screenshotFiltering:"native",platform:"darwin"'
    new_cap = 'screenshotFiltering:"native",platform:process.platform'
    if old_cap in content:
        content = content.replace(old_cap, new_cap, 1)
        total_patched += 1
        print('  [found] HFt capabilities platform constant')

    # Pattern 7: Computer-use MCP server registration gate
    # v1.1.x: process.platform==="darwin"&&t.push(await wZr())
    # v1.2.x: vee()&&t.push(await upn())  where vee() checks ese Set
    # Without this, the CLI agent never sees the mcp__computer-use tool.
    #
    # Approach: patch the ese Set to include "linux" (covers vee() gate
    # AND the platform support check), plus keep legacy pattern as fallback.

    # v1.2.x: Add "linux" to the supported platforms Set
    #   new Set(["darwin","win32"])  →  new Set(["darwin","win32","linux"])
    pattern_platform_set = r'new Set\(\["darwin","win32"\]\)'
    for match in reversed(list(re.finditer(pattern_platform_set, content))):
        # Verify context: should be near computer-use / vee function
        ctx = content[match.end():match.end() + 200]
        if 'platform' in ctx or 'computerUse' in ctx or 'screenshotFiltering' in ctx:
            replacement = 'new Set(["darwin","win32","linux"])'
            content = content[:match.start()] + replacement + content[match.end():]
            total_patched += 1
            print('  [found] Platform support Set: added "linux"')
            break

    # Legacy v1.1.x fallback: process.platform==="darwin"&&t.push(await fn())
    pattern_mcp_reg = (
        r'process\.platform==="darwin"&&(\w+)\.push\(await (\w+)\(\)\)'
    )
    for match in reversed(list(re.finditer(pattern_mcp_reg, content))):
        arr_var = match.group(1)
        fn_name = match.group(2)
        start = max(0, match.start() - 200)
        context = content[start:match.end() + 200]
        if 'computer-use' in context or 'serverName:' in context or 'Imagine' in context[match.end()-start:]:
            replacement = (
                f'(process.platform==="darwin"||process.platform==="linux")'
                f'&&{arr_var}.push(await {fn_name}())'
            )
            content = content[:match.start()] + replacement + content[match.end():]
            total_patched += 1
            print(f'  [found] Computer-use MCP server registration gate (legacy): {fn_name}()')
            break

    # Pattern 8: Server-side feature flag override
    #   function X(){return!1}function Y(){return X()?!0:js(...)}
    # X() is a hardcoded override that always returns false, meaning the
    # computer-use "enabled" check always hits the server-side GrowthBook flag.
    # On Linux the server flag isn't enabled, so we patch X() to return true,
    # which makes Y() short-circuit to !0 (enabled) unconditionally.
    pattern_override = (
        r'function\s+([\w$]+)\(\)\{return!1\}'
        r'(function\s+([\w$]+)\(\)\{return\s*\1\(\)\?!0:)'
    )
    for match in reversed(list(re.finditer(pattern_override, content))):
        override_fn = match.group(1)
        wrapper_fn = match.group(3)
        # Verify context: the wrapper should be used by hasComputerUse
        end_ctx = content[match.end():match.end() + 300]
        if 'chicagoEnabled' in end_ctx or 'platform' in end_ctx:
            replacement = (
                f'function {override_fn}(){{return!0}}'
                f'{match.group(2)}'
            )
            content = content[:match.start()] + replacement + content[match.end():]
            total_patched += 1
            print(f'  [found] Server-side feature flag override: {override_fn}() → true')
            break

    # Pattern 9: createDarwinExecutor platform guard
    # v1.1.x: ...`createDarwinExecutor called on ${process.platform}. Computer control is macOS-only in Phase 1.`
    # v1.2.x: ...`createDarwinExecutor called on ${process.platform}. Use createWin32Executor for Windows.`
    # This blocks ALL computer-use tool execution on non-darwin platforms.
    executor_patterns = [
        # v1.2.x format
        (
            r'if\(process\.platform!=="darwin"\)'
            r'throw new Error\(`createDarwinExecutor called on \$\{process\.platform\}\.'
            r' Use createWin32Executor for Windows\.`\)'
        ),
        # v1.1.x format (legacy)
        (
            r'if\(process\.platform!=="darwin"\)'
            r'throw new Error\(`createDarwinExecutor called on \$\{process\.platform\}\.'
            r' Computer control is macOS-only in Phase 1\.`\)'
        ),
    ]
    for pattern_executor in executor_patterns:
        for match in reversed(list(re.finditer(pattern_executor, content))):
            # Replace: allow Linux through, keep original error for other platforms
            original_throw = match.group(0)[len('if(process.platform!=="darwin")'):]
            replacement = (
                'if(process.platform!=="darwin"&&process.platform!=="linux")'
                + original_throw
            )
            content = content[:match.start()] + replacement + content[match.end():]
            total_patched += 1
            print(f'  [found] createDarwinExecutor platform guard')

    # Pattern 10: App resolution function — auto-resolve unknown apps on Linux
    # The app resolver matches requested names against installed apps. On Linux,
    # listInstalledApps() may not have macOS bundle names (e.g. "Finder"), so
    # apps come back with resolved=null → denied as "not_installed".
    # Fix: inject a Linux auto-resolve just before the "didYouMean" / bundleId
    # extraction that follows all lookup attempts.
    #
    # We match the pattern: }}<resolved_var>=<resolved_var>==null?void 0:<resolved_var>.bundleId
    # which appears right after all resolution attempts. We inject our Linux
    # fallback just before this point.
    #
    # Variant A (v1.2.234 simple): a||(a=n.get(s.toLowerCase()));const o=a==null?void 0:a.bundleId
    # Variant B (v1.2.234+ AUMID):  ...}}}const u=l?void 0:A7r(c,e),d=l==null?void 0:l.bundleId
    app_resolve_patterns = [
        # Variant A: simple — semicolon before const, resolved==null check
        (
            r'(\w)\|\|\(\1=(\w)\.get\((\w)\.toLowerCase\(\)\)\);'
            r'(const \w=\1==null\?void 0:\1\.bundleId)',
            lambda m: (
                f'{m.group(1)}||({m.group(1)}={m.group(2)}.get({m.group(3)}.toLowerCase()));'
                f'if(!{m.group(1)}&&process.platform==="linux")'
                f'{{{m.group(1)}={{bundleId:{m.group(3)},displayName:{m.group(3)},path:{m.group(3)}}}}}'
                f'{m.group(4)}'
            )
        ),
        # Variant B: AUMID fallback — inject before the didYouMean/bundleId extraction
        # Pattern: }}}const <u>=<l>?void 0:<fn>(<c>,<e>),<d>=<l>==null?void 0:<l>.bundleId
        # We match on the resolved-var null check: <d>=<l>==null?void 0:<l>.bundleId
        # and the preceding requestedName var from the map callback: .map(<c>=>{let <l>=
        (
            r'\.map\((\w)=>\{let (\w)=',
            None  # handled specially below
        ),
    ]
    # Try variant A first
    pat_a, repl_a = app_resolve_patterns[0]
    for match in reversed(list(re.finditer(pat_a, content))):
        content = content[:match.start()] + repl_a(match) + content[match.end():]
        total_patched += 1
        print(f'  [found] App resolution function: auto-resolve on Linux (variant A)')
        break
    else:
        # Try variant B: AUMID fallback code structure (v1.2.234+)
        # Find the .map callback to get the requestedName and resolved variable names
        pat_map = r'\.map\((\w)=>\{let (\w)=\w\.get\(\1\)'
        map_match = re.search(pat_map, content)
        if map_match:
            req_var = map_match.group(1)  # requestedName (e.g. c)
            res_var = map_match.group(2)  # resolved (e.g. l)
            # Find: }}}const <u>=<l>?void 0:  (the didYouMean assignment after all lookups)
            # We inject our Linux fallback before this const declaration.
            anchor_pat = re.compile(
                r'\}\}\}(const \w=' + re.escape(res_var) + r'\?void 0:)'
            )
            for anchor in anchor_pat.finditer(content, map_match.start()):
                inject = (
                    f'if(!{res_var}&&process.platform==="linux")'
                    f'{{{res_var}={{bundleId:{req_var},displayName:{req_var},path:{req_var}}}}}'
                )
                # Insert after }}} and before const
                insert_pos = anchor.start() + 3  # after }}}
                content = content[:insert_pos] + inject + content[insert_pos:]
                total_patched += 1
                print(f'  [found] App resolution function: auto-resolve on Linux (variant B)')
                break

    # Pattern 11: Pg() setIgnoreMouseEvents wrapper — skip on Linux
    # On macOS, Pg() sets setIgnoreMouseEvents(true) on all BrowserWindows during
    # input actions (click, drag, scroll) to prevent the Claude window from
    # intercepting clicks. On Linux (especially Wayland), this causes severe
    # flickering and visual glitches because compositors handle this differently.
    # Fix: on Linux, skip the setIgnoreMouseEvents calls entirely.
    # JS identifiers can start with $ so use [\w$] throughout
    _id = r'[\w$]+'   # matches JS identifiers like $g, $en, qIe
    _v = r'[\w$]'     # single-char JS identifier
    pattern_pg = (
        r'async function (' + _id + r')\((' + _v + r')\)\{'
        r'const (' + _v + r')=(' + _id + r')\.BrowserWindow\.getAllWindows\(\)\.filter\((' + _v + r')=>!\5\.isDestroyed\(\)\);'
        r'for\(const (' + _v + r') of \3\)\6\.setIgnoreMouseEvents\(!0\);'
        r'await (' + _id + r')\((' + _id + r')\);'
        r'try\{return await \2\(\)\}'
        r'finally\{for\(const (' + _v + r') of \3\)!\9\.isDestroyed\(\)&&!(' + _id + r')\.has\(\9\.id\)&&\9\.setIgnoreMouseEvents\(!1\)\}'
        r'\}'
    )
    for match in reversed(list(re.finditer(pattern_pg, content))):
        fn_name = match.group(1)
        cb_var = match.group(2)
        arr_var = match.group(3)
        xe_var = match.group(4)
        filt_var = match.group(5)
        iter_var = match.group(6)
        gm_fn = match.group(7)
        delay_var = match.group(8)
        iter2_var = match.group(9)
        set_var = match.group(10)
        # On Linux: just run the callback directly, no mouse-event toggling
        replacement = (
            f'async function {fn_name}({cb_var}){{'
            f'if(process.platform==="linux"){{return await {cb_var}()}}'
            f'const {arr_var}={xe_var}.BrowserWindow.getAllWindows().filter({filt_var}=>!{filt_var}.isDestroyed());'
            f'for(const {iter_var} of {arr_var}){iter_var}.setIgnoreMouseEvents(!0);'
            f'await {gm_fn}({delay_var});'
            f'try{{return await {cb_var}()}}'
            f'finally{{for(const {iter2_var} of {arr_var})!{iter2_var}.isDestroyed()&&!{set_var}.has({iter2_var}.id)&&{iter2_var}.setIgnoreMouseEvents(!1)}}'
            f'}}'
        )
        content = content[:match.start()] + replacement + content[match.end():]
        total_patched += 1
        print(f'  [found] Pg() setIgnoreMouseEvents wrapper: skip on Linux')
        break

    if total_patched == 0:
        print('  [skip] No computer use platform gates found')
        return content, False

    print(f'  [ok] Patched {total_patched} computer use gate(s)')
    return content, True
