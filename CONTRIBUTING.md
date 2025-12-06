# Contributing

Thank you for your interest in contributing to this Home Assistant add-ons repository!

## Adding a New Add-on

1. Create a new directory in the repository root with your add-on name
2. Add the following required files:
   - `config.json` - Add-on configuration
   - `Dockerfile` - Docker build instructions
   - `README.md` - Add-on documentation
   - `run.sh` - Startup script (if needed)

3. Update the main `README.md` to list your add-on

## Testing Your Add-on Locally

Before submitting, test your add-on:

1. Build the Docker image:
   ```bash
   docker build -t local/addon-name ./addon-name
   ```

2. Test the configuration:
   ```bash
   jq empty addon-name/config.json
   ```

3. Lint the Dockerfile:
   ```bash
   hadolint addon-name/Dockerfile
   ```

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
- Follow shell script best practices for `run.sh` scripts
- Keep Dockerfiles simple and well-commented
- Document all configuration options

## Questions?

Feel free to open an issue if you have questions about contributing!
