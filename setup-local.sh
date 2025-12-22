#!/bin/bash

# Quick setup script for local development

echo "=========================================="
echo "Deployment App - Local Setup"
echo "=========================================="
echo ""

# Detect Python
if command -v python3 &> /dev/null; then
    PYTHON_CMD="python3"
elif command -v python &> /dev/null; then
    PYTHON_CMD="python"
else
    echo "ERROR: Python not found"
    exit 1
fi

echo "Using: $PYTHON_CMD ($($PYTHON_CMD --version))"
echo ""

# Option 1: Virtual environment (recommended)
read -p "Do you want to use a virtual environment? (recommended) [Y/n]: " USE_VENV
USE_VENV=${USE_VENV:-Y}

if [[ $USE_VENV =~ ^[Yy]$ ]]; then
    echo ""
    echo "Creating virtual environment..."
    $PYTHON_CMD -m venv venv

    echo "Activating virtual environment..."
    source venv/bin/activate

    echo "Installing dependencies..."
    pip install -r requirements.txt

    echo ""
    echo "=========================================="
    echo "Setup complete!"
    echo "=========================================="
    echo ""
    echo "To run the app:"
    echo "  1. Activate venv: source venv/bin/activate"
    echo "  2. Run app: python app.py"
    echo "  3. Open browser: http://localhost:8080"
    echo ""
    echo "To deactivate venv later:"
    echo "  deactivate"
    echo ""
else
    echo ""
    echo "Installing dependencies globally..."
    pip3 install -r requirements.txt

    echo ""
    echo "=========================================="
    echo "Setup complete!"
    echo "=========================================="
    echo ""
    echo "To run the app:"
    echo "  python3 app.py"
    echo "  Open browser: http://localhost:8080"
    echo ""
fi
