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
    #   process.platform==="darwin"&&t.push(await wZr())
    # The computer-use MCP server is only registered on macOS.
    # Without this, the CLI agent never sees the mcp__computer-use tool.
    pattern_mcp_reg = (
        r'process\.platform==="darwin"&&(\w+)\.push\(await (\w+)\(\)\)'
    )
    # We need to be careful to only match the one near wZr/computer-use context.
    # Look for pattern that follows the louderPenguinEnabled block and precedes getImagineServerDef.
    for match in reversed(list(re.finditer(pattern_mcp_reg, content))):
        arr_var = match.group(1)
        fn_name = match.group(2)
        # Verify this is the computer-use registration by checking nearby context
        start = max(0, match.start() - 200)
        context = content[start:match.end() + 200]
        if 'computer-use' in context or 'serverName:' in context or 'Imagine' in context[match.end()-start:]:
            replacement = (
                f'(process.platform==="darwin"||process.platform==="linux")'
                f'&&{arr_var}.push(await {fn_name}())'
            )
            content = content[:match.start()] + replacement + content[match.end():]
            total_patched += 1
            print(f'  [found] Computer-use MCP server registration gate: {fn_name}()')
            break  # Only patch this one occurrence

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
    #   function LHr(t){if(process.platform!=="darwin")throw new Error(`createDarwinExecutor called on ${process.platform}...`)
    # This blocks ALL computer-use tool execution on non-darwin platforms.
    pattern_executor = (
        r'if\(process\.platform!=="darwin"\)'
        r'throw new Error\(`createDarwinExecutor called on \$\{process\.platform\}\.'
        r' Computer control is macOS-only in Phase 1\.`\)'
    )
    for match in reversed(list(re.finditer(pattern_executor, content))):
        replacement = (
            'if(process.platform!=="darwin"&&process.platform!=="linux")'
            'throw new Error(`createDarwinExecutor called on ${process.platform}.'
            ' Computer control is macOS-only in Phase 1.`)'
        )
        content = content[:match.start()] + replacement + content[match.end():]
        total_patched += 1
        print(f'  [found] createDarwinExecutor platform guard')

    if total_patched == 0:
        print('  [skip] No computer use platform gates found')
        return content, False

    print(f'  [ok] Patched {total_patched} computer use gate(s)')
    return content, True
