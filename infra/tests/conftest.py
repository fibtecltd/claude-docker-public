import sys
from pathlib import Path

# Make `stacks` importable the same way `python app.py` does.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
