"""Ensure secureVmFeaturesEnabled is not forced off."""


def apply(content):
    """
    Check that secureVmFeaturesEnabled isn't set to false.

    The enterprise config reader (hc()) returns {} on Linux, which is fine.
    But if the minified code hardcodes it to false, flip it to true.
    """
    if 'secureVmFeaturesEnabled:!1' in content:
        content = content.replace('secureVmFeaturesEnabled:!1', 'secureVmFeaturesEnabled:!0')
        print('  [ok] Flipped secureVmFeaturesEnabled from false to true')
    elif 'secureVmFeaturesEnabled:false' in content:
        content = content.replace('secureVmFeaturesEnabled:false', 'secureVmFeaturesEnabled:true')
        print('  [ok] Flipped secureVmFeaturesEnabled from false to true')
    else:
        print('  [skip] secureVmFeaturesEnabled not set to false')

    return content, True
