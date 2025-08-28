# 🤝 Contributing to Easy_Splunk

Thank you for your interest in contributing to Easy_Splunk! This guide will help you get started with development and contributions.

## 🚀 Quick Start for Contributors

1. **Fork and Clone** the repository
2. **Read the docs** - Start with [Quick Start Guide](QUICK_START.md)
3. **Run the tests** - `./tests/smoke/smoke_generate_compose.sh`
4. **Make your changes** following our standards
5. **Submit a Pull Request**

## 📚 Documentation Structure

Our documentation is organized for maximum discoverability:

### User-Focused Guides
- **[Quick Start Guide](QUICK_START.md)** - Get running in 5 minutes
- **[Docker vs Podman Guide](DOCKER_PODMAN_GUIDE.md)** - Runtime selection explained
- **[Enhanced Error Handling: Start Here](ENHANCED_ERROR_START_HERE.md)** - Quick fixes for issues

### Technical Documentation
- **[Installation Guide](docs/INSTALLATION.md)** - Complete setup instructions
- **[Bash Best Practices](docs/BASH_BEST_PRACTICES_GUIDE.md)** - Coding standards
- **[Enhanced Error Handling](ENHANCED_ERROR_HANDLING.md)** - Implementation details

## 🧪 Testing

Before submitting changes:

```bash
# Run smoke tests
./tests/smoke/smoke_generate_compose.sh
./tests/smoke/smoke_airgapped_bundle.sh

# Run shellcheck on your changes
shellcheck your-script.sh

# Test deployment (if applicable)
./deploy.sh --config config-templates/development.conf
```

## 📝 Coding Standards

### Bash Scripting
- Follow [Bash Best Practices](docs/BASH_BEST_PRACTICES_GUIDE.md)
- Use `shellcheck` to validate scripts
- Include proper error handling
- Add comprehensive comments

### Documentation
- Keep user guides in root directory (Quick Start, etc.)
- Put technical docs in `docs/` directory
- Use consistent formatting and emojis
- Include working code examples

### Commit Messages
```
feat: add new deployment option
fix: resolve podman-compose issue on RHEL 8
docs: update quick start guide
test: add smoke test for air-gapped bundles
```

## 🐛 Reporting Issues

When reporting bugs, please include:

1. **Error messages** (copy-paste exact output)
2. **System information** (OS, Docker/Podman version)
3. **Steps to reproduce** (exact commands used)
4. **Expected vs actual behavior**

## 💡 Feature Requests

For new features, please:

1. **Check existing docs** - Your idea might already exist!
2. **Open a Discussion** first to discuss the feature
3. **Provide use cases** - Why is this needed?
4. **Consider alternatives** - What other solutions exist?

## 🔧 Development Setup

```bash
# Install development dependencies
./install-prerequisites.sh --yes

# Run all tests
./run_all_tests.sh

# Generate test documentation
./generate-monitoring-config.sh
```

## 📞 Getting Help

- **Documentation**: Start with [Quick Start Guide](QUICK_START.md)
- **Issues**: Use GitHub Issues for bugs
- **Discussions**: Use GitHub Discussions for questions
- **Code Reviews**: All PRs require review

## 🎉 Recognition

Contributors will be recognized in:
- Release notes
- Contributors file (future)
- GitHub's contributor insights

Thank you for helping make Easy_Splunk better! 🚀
