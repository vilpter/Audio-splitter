#!/usr/bin/env python3
"""
JSON Parser Helper for audio-splitter.sh
Replaces jq dependency with Python json module
"""

import json
import sys

def main():
    if len(sys.argv) < 3:
        print("Usage: json-parser.py <json_file> <query>", file=sys.stderr)
        print("Queries:", file=sys.stderr)
        print("  validate              - Validate JSON syntax", file=sys.stderr)
        print("  count                 - Count splits", file=sys.stderr)
        print("  has_splits            - Check if splits array exists", file=sys.stderr)
        print("  get_split N           - Get split at index N as JSON", file=sys.stderr)
        print("  get_field N field     - Get field from split N", file=sys.stderr)
        sys.exit(1)
    
    json_file = sys.argv[1]
    query = sys.argv[2]
    
    try:
        with open(json_file, 'r') as f:
            data = json.load(f)
    except json.JSONDecodeError as e:
        print(f"Invalid JSON: {e}", file=sys.stderr)
        sys.exit(1)
    except FileNotFoundError:
        print(f"File not found: {json_file}", file=sys.stderr)
        sys.exit(1)
    
    if query == "validate":
        # If we got here, JSON is valid
        print("valid")
        sys.exit(0)
    
    elif query == "has_splits":
        if "splits" in data and isinstance(data["splits"], list):
            print("true")
        else:
            print("false")
        sys.exit(0)
    
    elif query == "count":
        if "splits" in data:
            print(len(data["splits"]))
        else:
            print("0")
        sys.exit(0)
    
    elif query == "get_split":
        if len(sys.argv) < 4:
            print("Missing split index", file=sys.stderr)
            sys.exit(1)
        
        index = int(sys.argv[3])
        if "splits" in data and 0 <= index < len(data["splits"]):
            print(json.dumps(data["splits"][index]))
        else:
            print("{}")
        sys.exit(0)
    
    elif query == "get_field":
        if len(sys.argv) < 5:
            print("Missing split index or field name", file=sys.stderr)
            sys.exit(1)
        
        index = int(sys.argv[3])
        field = sys.argv[4]
        
        if "splits" in data and 0 <= index < len(data["splits"]):
            split = data["splits"][index]
            value = split.get(field, "")
            print(value)
        else:
            print("")
        sys.exit(0)
    
    else:
        print(f"Unknown query: {query}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
