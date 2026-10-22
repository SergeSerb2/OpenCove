#!/usr/bin/env python3
"""Safe real-app smoke entry point. See --help; hardware writes are opt-in only."""
import sys
from control_e2e import main

if __name__ == "__main__":
    sys.exit(main())
