# Contributing to AI Photo Edit

Thank you for your interest in contributing to AI Photo Edit!

## Development Setup

1. Fork the repository
2. Clone your fork
3. Create a feature branch
4. Make your changes
5. Test your changes
6. Submit a pull request

## Development Environment

### Using Docker (Recommended)

```bash
# Start dev environment with hot-reload
docker-compose -f docker-compose.dev.yml up
```

### Local Development

**Backend**
```bash
cd backend
python -m venv venv
source venv/bin/activate  # On Windows: venv\Scripts\activate
pip install -r requirements.txt
uvicorn app.main:app --reload
```

**Frontend**
```bash
cd frontend
npm install
npm run dev
```

## Code Style

### Python (Backend)
- Follow PEP 8
- Use type hints where appropriate
- Add docstrings to functions and classes

### JavaScript/React (Frontend)
- Use functional components with hooks
- Follow React best practices
- Use meaningful variable names

## Pull Request Process

1. Update the README.md with details of changes if needed
2. Ensure all tests pass
3. Update documentation as needed
4. Get approval from maintainers
5. Squash commits if requested

## Reporting Bugs

When reporting bugs, please include:
- Description of the issue
- Steps to reproduce
- Expected behavior
- Actual behavior
- Screenshots if applicable
- Environment details (OS, Docker version, etc.)

## Feature Requests

We welcome feature requests! Please:
- Check if the feature already exists
- Explain the use case
- Describe the expected behavior
- Consider if it aligns with project goals

## Code of Conduct

- Be respectful and inclusive
- Welcome newcomers
- Focus on constructive feedback
- Respect differing opinions

Thank you for contributing!
