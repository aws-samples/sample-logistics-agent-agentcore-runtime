"""
Create a zip file from the agent bundle directory.
This script is used during the CDK bundling process.
"""
import zipfile
import os
import sys
import tempfile
from pathlib import Path

def main():
    # Use environment variables with fallback to system temp directory
    if 'BUNDLE_DIR' in os.environ:
        bundle_dir = Path(os.environ['BUNDLE_DIR'])
    else:
        bundle_dir = Path(tempfile.gettempdir()) / 'agent-bundle'
    
    if 'OUTPUT_ZIP' in os.environ:
        output_zip = Path(os.environ['OUTPUT_ZIP'])
    else:
        output_zip = Path('/asset-output/agent-code.zip')
    
    # Validate bundle directory exists
    if not bundle_dir.exists():
        print(f"Error: Bundle directory does not exist: {bundle_dir}", file=sys.stderr)
        return 1
    
    # Ensure output directory exists
    output_zip.parent.mkdir(parents=True, exist_ok=True)
    
    # Filter out __pycache__ directories
    ignore_dirs = {'__pycache__', '.git', '.venv', 'node_modules'}
    
    try:
        file_count = 0
        with zipfile.ZipFile(output_zip, 'w', zipfile.ZIP_DEFLATED) as zipf:
            for root, dirs, files in os.walk(bundle_dir):
                # Filter out ignored directories
                dirs[:] = [d for d in dirs if d not in ignore_dirs]
                
                rel_root = os.path.relpath(root, bundle_dir)
                if rel_root == '.':
                    rel_root = ''
                
                for file in files:
                    file_path = Path(root) / file
                    # Use relative path from bundle_dir as arcname (files at root)
                    file_rel = os.path.join(rel_root, file) if rel_root else file
                    zipf.write(file_path, file_rel)
                    file_count += 1
        
        print(f"Created zip with {file_count} files")
        return 0
    except Exception as e:
        print(f"Error creating zip file: {e}", file=sys.stderr)
        return 1

if __name__ == '__main__':
    sys.exit(main())