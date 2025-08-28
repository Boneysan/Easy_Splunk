# Developer Scripts

This directory contains alternative implementations and development versions of core scripts. These are **not intended for production use** but are kept for reference and development purposes.

## Scripts Overview

### Deploy Scripts
- **`deploy-main.sh`** - Alternative deployment implementation with different approach
- **`deploy_clean.sh`** - Minimal deployment wrapper (51 lines)
- **`deploy_fixed.sh`** - Deployment script with specific fixes applied
- **`deploy_with_fixes.sh`** - Wrapper that applies all known fixes before deployment

### Usage Notes

**⚠️ Important:** These scripts are development artifacts and may:
- Have different command-line interfaces
- Use different configuration approaches
- Contain experimental features
- Have different error handling

**For production use, always use:**
- `../deploy.sh` - The authoritative deployment script
- `../bin/easy-splunk deploy` - The unified entry point

### Development Workflow

When making changes to deployment logic:

1. Test changes with the main `deploy.sh` first
2. If needed, create experimental versions in this directory
3. Document differences and rationale
4. Consider integrating successful changes back to the main script

### Cleanup

These scripts may be removed in future versions as the codebase consolidates. Always check the main scripts first for the latest features and fixes.

## Contributing

If you find issues with these scripts or want to propose improvements:

1. Test with the main `deploy.sh` first
2. Open an issue describing the problem
3. Reference the specific dev script if relevant
4. Propose changes to the main script rather than modifying dev scripts
