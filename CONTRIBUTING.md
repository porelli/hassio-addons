# Contributing

Thank you for your interest in contributing to this Home Assistant add-ons repository!

## Adding a New Add-on

1. Create a new directory in the repository root with your add-on name (the same as its `slug`)
2. Add the files of an app (contributors.home-assistant.io/apps/reference/files):
   - `config.yaml` - Add-on configuration
   - `Dockerfile` - Docker build instructions
   - `README.md`, `DOCS.md`, `CHANGELOG.md` - the store's introduction, the Documentation tab,
     the changes by version
   - `icon.png` (128x128), `logo.png`, `translations/en.yaml`, `apparmor.txt`

3. Add it to the matrices of `.github/workflows/builder.yml` and `lint.yml`, and list it in
   the main `README.md`

## Testing Your Add-on Locally

Before submitting, test your add-on:

1. Build the Docker image:
   ```bash
   docker build -t local/addon-name ./addon-name
   ```

2. Lint the configuration with the app linter (what CI runs):
   ```bash
   docker run --rm -e INPUT_PATH=/addon -v "$PWD/addon-name:/addon:ro" \
     "$(docker build -q https://github.com/frenck/action-app-linter.git#v2.21.2:src)"
   ```

3. Lint the Dockerfile:
   ```bash
   hadolint addon-name/Dockerfile
   ```

The Firefox Sync add-ons have their own tests in `tests/` (see the main README).

## Submitting Changes

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/my-addon`
3. Make your changes
4. Ensure all files are properly formatted
5. Commit with a clear message: `git commit -m "Add: My Addon"`
6. Push to your fork: `git push origin feature/my-addon`
7. Open a Pull Request

## Pull Request Guidelines

- Ensure your add-on follows the Home Assistant add-on structure
- Include clear documentation in the README.md
- Test that the add-on builds successfully
- Keep commits focused and atomic
- Write clear commit messages

## Code Style

- Use 2 spaces for indentation in YAML/JSON
- Follow shell script best practices (ShellCheck runs in CI)
- Keep Dockerfiles simple and well-commented
- Document all configuration options

## Questions?

Feel free to open an issue if you have questions about contributing!
