# Contributing to Monet

Thank you for your interest in contributing to Monet! This document provides guidelines and information for contributors.

## Getting Started

### Prerequisites

- macOS 14.0 (Sonoma) or later
- Xcode 15.0 or later
- Git

### Setup

1. Fork the repository
2. Clone your fork:
   ```bash
   git clone https://github.com/YOUR_USERNAME/Monet.git
   cd Monet
   ```
3. Open the project:
   ```bash
   open Monet.xcodeproj
   ```
4. Build and run with `Cmd+R`

## How to Contribute

### Reporting Bugs

Before submitting a bug report:
- Check existing [issues](../../issues) to avoid duplicates
- Include macOS version, Monet version, and steps to reproduce

### Suggesting Features

Open an issue with:
- Clear description of the feature
- Use case and benefits
- Any implementation ideas (optional)

### Pull Requests

1. Create a feature branch:
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. Make your changes following the code style guidelines below

3. Test your changes thoroughly

4. Commit with clear messages:
   ```bash
   git commit -m "Add feature: brief description"
   ```

5. Push and open a PR against `main`

## Code Style

- Follow existing code patterns and conventions
- Use Swift's standard naming conventions
- Keep functions focused and concise
- Add comments for complex logic only

### Project Structure

```
Monet/
├── Models/          # Data structures
├── Views/           # SwiftUI views
├── ViewModels/      # State management
├── Services/        # API, Auth, Keychain
├── Utilities/       # Helpers, Constants
└── Resources/       # Assets, Info.plist
```

## Testing

- Test on macOS 14+ before submitting
- Verify both Claude Code credentials and OAuth flows
- Check all display modes (Minimal, Normal, Verbose)

## Questions?

Open an issue for any questions about contributing.

---

Thank you for helping improve Monet!
