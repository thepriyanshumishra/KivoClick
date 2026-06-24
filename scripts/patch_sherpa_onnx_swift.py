import sys
import glob
import os
import stat

# Find the SherpaOnnx.swift file in DerivedData checkouts
files = glob.glob('/Users/thedarkpcm/Library/Developer/Xcode/DerivedData/leanring-buddy-*/SourcePackages/checkouts/sherpa-onnx-spm/Sources/SherpaOnnx/SherpaOnnx.swift')

if not files:
    print("Could not find SherpaOnnx.swift in DerivedData checkouts.")
    sys.exit(1)

for file_path in files:
    print(f"Patching {file_path} to make APIs public...")
    
    # Make file writable
    os.chmod(file_path, stat.S_IWRITE | stat.S_IREAD)
    
    with open(file_path, 'r') as f:
        lines = f.readlines()

    new_lines = []
    context_stack = []
    in_multiline_comment = False

    for line in lines:
        stripped = line.strip()
        
        # Track multiline comments
        if '/*' in line:
            in_multiline_comment = True
        if '*/' in line:
            in_multiline_comment = False
            new_lines.append(line)
            continue
        if in_multiline_comment:
            new_lines.append(line)
            continue
            
        # Ignore comment lines or empty lines
        if stripped.startswith('//') or not stripped:
            new_lines.append(line)
            continue

        # Count braces
        open_braces = line.count('{')
        close_braces = line.count('}')
        
        modified_line = line
        
        # Check current context BEFORE updating for open braces on this line
        is_top_level = len(context_stack) == 0
        is_inside_type_only = len(context_stack) > 0 and all(c == 'type' for c in context_stack)
        
        if is_top_level:
            if (stripped.startswith('class ') or stripped.startswith('final class ') or 
                stripped.startswith('struct ') or stripped.startswith('func ') or 
                stripped.startswith('typealias ')):
                if not any(stripped.startswith(prefix) for prefix in ['public ', 'private ', 'internal ']):
                    modified_line = line.replace('class ', 'public class ', 1) \
                                        .replace('struct ', 'public struct ', 1) \
                                        .replace('func ', 'public func ', 1) \
                                        .replace('typealias ', 'public typealias ', 1)
                                        
        elif is_inside_type_only:
            if (stripped.startswith('class ') or stripped.startswith('final class ') or 
                stripped.startswith('struct ')):
                if not any(stripped.startswith(prefix) for prefix in ['public ', 'private ', 'internal ']):
                    modified_line = line.replace('class ', 'public class ', 1) \
                                        .replace('struct ', 'public struct ', 1)
            elif (stripped.startswith('init(') or stripped.startswith('init ') or
                  stripped.startswith('func ') or stripped.startswith('var ') or 
                  stripped.startswith('let ')):
                if not any(stripped.startswith(prefix) for prefix in ['public ', 'private ', 'internal ', 'static ', 'class ']):
                    leading_spaces = len(line) - len(line.lstrip())
                    spaces = line[:leading_spaces]
                    rest = line[leading_spaces:]
                    modified_line = spaces + 'public ' + rest
                elif stripped.startswith('static var ') or stripped.startswith('static let ') or stripped.startswith('static func '):
                    leading_spaces = len(line) - len(line.lstrip())
                    spaces = line[:leading_spaces]
                    rest = line[leading_spaces:]
                    modified_line = spaces + 'public ' + rest

        # Update context stack for open braces
        for _ in range(open_braces):
            # Check if entering type or func
            # Ensure class func and class var are NOT treated as type definitions
            is_type_definition = ('class ' in line or 'struct ' in line) and not ('class func' in line or 'class var' in line)
            
            if len(context_stack) == 0:
                if is_type_definition:
                    context_stack.append('type')
                else:
                    context_stack.append('func')
            else:
                if context_stack[-1] == 'type':
                    if is_type_definition:
                        context_stack.append('type')
                    else:
                        context_stack.append('func')
                else:
                    context_stack.append('func')
                    
        # Update context stack for close braces
        for _ in range(close_braces):
            if len(context_stack) > 0:
                context_stack.pop()

        new_lines.append(modified_line)

    with open(file_path, 'w') as f:
        f.writelines(new_lines)

print("Patching SherpaOnnx.swift complete!")
