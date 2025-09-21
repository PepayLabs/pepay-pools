#!/usr/bin/env python3
"""
Advanced Lifinity V2 Bytecode Analysis Tool
This tool systematically analyzes the BPF bytecode to extract accurate patterns
"""

import re
import json
from collections import defaultdict, Counter
from typing import Dict, List, Tuple, Optional

class LifinityBytecodeAnalyzer:
    def __init__(self, disasm_path: str):
        self.disasm_path = disasm_path
        self.instructions = []
        self.function_calls = []
        self.memory_operations = []
        self.constants = []
        self.control_flow = defaultdict(list)
        self.stack_operations = []

    def parse_disassembly(self):
        """Parse the entire disassembly file"""
        print("Parsing disassembly file...")
        with open(self.disasm_path, 'r') as f:
            lines = f.readlines()

        for i, line in enumerate(lines):
            if '\t' in line and ':' in line:
                try:
                    # Extract instruction details
                    parts = line.strip().split('\t')
                    if len(parts) >= 3:
                        addr = parts[0].split(':')[0].strip()
                        bytecode = parts[1]
                        instruction = parts[2] if len(parts) > 2 else ""

                        self.instructions.append({
                            'line': i + 1,
                            'addr': addr,
                            'bytecode': bytecode,
                            'instruction': instruction,
                            'raw': line.strip()
                        })

                        # Analyze instruction type
                        self._analyze_instruction(addr, bytecode, instruction)
                except:
                    continue

        print(f"Parsed {len(self.instructions)} instructions")

    def _analyze_instruction(self, addr: str, bytecode: str, instruction: str):
        """Categorize and analyze each instruction"""

        # Function calls (85 10 = call)
        if 'call 0x' in instruction:
            target = instruction.split('call ')[1]
            self.function_calls.append({
                'addr': addr,
                'target': target,
                'instruction': instruction
            })

        # Memory operations (7b = store, 79 = load)
        elif bytecode.startswith('7b') or bytecode.startswith('79'):
            is_store = bytecode.startswith('7b')
            self.memory_operations.append({
                'addr': addr,
                'type': 'store' if is_store else 'load',
                'instruction': instruction
            })

        # Constants (18 = load immediate 64-bit)
        elif bytecode.startswith('18'):
            # Extract the constant value
            if 'll' in instruction:
                const_match = re.search(r'= (0x[0-9a-f]+)', instruction)
                if const_match:
                    self.constants.append({
                        'addr': addr,
                        'value': const_match.group(1),
                        'instruction': instruction
                    })

        # Control flow (55 = jne, 15 = jeq, 05 = goto, 1d = je)
        elif bytecode.startswith(('55', '15', '05', '1d', '5d')):
            jump_type = {
                '55': 'jne',
                '15': 'jeq',
                '05': 'goto',
                '1d': 'je',
                '5d': 'jne'
            }.get(bytecode[:2], 'unknown')

            self.control_flow[jump_type].append({
                'addr': addr,
                'instruction': instruction
            })

        # Stack operations (bf = mov, 07 = add to register)
        elif bytecode.startswith(('bf', '07')):
            self.stack_operations.append({
                'addr': addr,
                'type': 'mov' if bytecode.startswith('bf') else 'add',
                'instruction': instruction
            })

    def extract_function_boundaries(self):
        """Identify function boundaries based on call patterns and control flow"""
        print("\nExtracting function boundaries...")

        functions = []
        current_function = None

        for i, inst in enumerate(self.instructions):
            # Function entry points often follow specific patterns
            # Look for common prologue patterns
            if 'r10' in inst['instruction'] and 'r1' in inst['instruction']:
                if current_function:
                    current_function['end'] = self.instructions[i-1]['addr']
                    functions.append(current_function)

                current_function = {
                    'start': inst['addr'],
                    'start_line': inst['line'],
                    'instructions': []
                }

            if current_function:
                current_function['instructions'].append(inst)

            # Function exit (95 00 = exit)
            if inst['bytecode'].startswith('95 00'):
                if current_function:
                    current_function['end'] = inst['addr']
                    current_function['end_line'] = inst['line']
                    functions.append(current_function)
                    current_function = None

        return functions

    def identify_discriminators(self):
        """Identify instruction discriminators from constants"""
        print("\nIdentifying instruction discriminators...")

        # Look for 8-byte constants that could be discriminators
        discriminators = []
        for const in self.constants:
            value = const['value']
            # Discriminators are typically 8 bytes
            if len(value) > 10:  # 0x + at least 8 hex chars
                discriminators.append({
                    'value': value,
                    'addr': const['addr'],
                    'context': self._get_context(const['addr'], 5)
                })

        return discriminators

    def _get_context(self, addr: str, lines: int = 3):
        """Get surrounding instructions for context"""
        context = []
        for inst in self.instructions:
            if inst['addr'] == addr:
                idx = self.instructions.index(inst)
                start = max(0, idx - lines)
                end = min(len(self.instructions), idx + lines + 1)
                context = self.instructions[start:end]
                break
        return context

    def map_memory_layout(self):
        """Map the memory layout based on store/load operations"""
        print("\nMapping memory layout...")

        memory_map = defaultdict(list)

        for mem_op in self.memory_operations:
            # Extract offset from instruction (e.g., r10 - 0xd8)
            offset_match = re.search(r'r10 - (0x[0-9a-f]+)', mem_op['instruction'])
            if offset_match:
                offset = offset_match.group(1)
                memory_map[offset].append({
                    'type': mem_op['type'],
                    'addr': mem_op['addr'],
                    'instruction': mem_op['instruction']
                })

        # Sort by offset
        sorted_map = dict(sorted(memory_map.items(), key=lambda x: int(x[0], 16)))

        return sorted_map

    def analyze_swap_logic(self):
        """Extract swap-specific logic patterns"""
        print("\nAnalyzing swap logic patterns...")

        swap_patterns = []

        # Look for characteristic swap patterns
        for i, inst in enumerate(self.instructions):
            # Multiplication patterns (often used in swap calculations)
            if '*' in inst['instruction'] or 'mul' in inst['instruction'].lower():
                context = self._get_context(inst['addr'], 10)
                swap_patterns.append({
                    'type': 'multiplication',
                    'addr': inst['addr'],
                    'context': context
                })

            # Division patterns
            if '/' in inst['instruction'] or 'div' in inst['instruction'].lower():
                context = self._get_context(inst['addr'], 10)
                swap_patterns.append({
                    'type': 'division',
                    'addr': inst['addr'],
                    'context': context
                })

        return swap_patterns

    def generate_pseudocode(self, functions: List[Dict]):
        """Generate pseudocode from identified functions"""
        print("\nGenerating pseudocode...")

        pseudocode = []

        for func in functions[:10]:  # First 10 functions for demo
            code = f"\n// Function at {func['start']} (lines {func['start_line']}-{func.get('end_line', '?')})\n"
            code += "function_" + func['start'] + "() {\n"

            # Analyze function instructions
            stack_frame = 0
            for inst in func['instructions'][:20]:  # Limit for readability
                if 'r10 -' in inst['instruction']:
                    # Stack allocation
                    offset_match = re.search(r'r10 - (0x[0-9a-f]+)', inst['instruction'])
                    if offset_match:
                        stack_frame = max(stack_frame, int(offset_match.group(1), 16))

                # Convert to pseudocode
                if inst['bytecode'].startswith('7b'):  # Store
                    code += f"    // {inst['instruction']}\n"
                    code += f"    store_to_stack();\n"
                elif inst['bytecode'].startswith('79'):  # Load
                    code += f"    // {inst['instruction']}\n"
                    code += f"    load_from_stack();\n"
                elif 'call' in inst['instruction']:
                    code += f"    // {inst['instruction']}\n"
                    code += f"    external_call();\n"

            code += f"    // Stack frame size: {stack_frame} bytes\n"
            code += "}\n"
            pseudocode.append(code)

        return pseudocode

    def generate_report(self):
        """Generate comprehensive analysis report"""
        print("\nGenerating analysis report...")

        functions = self.extract_function_boundaries()
        discriminators = self.identify_discriminators()
        memory_map = self.map_memory_layout()
        swap_patterns = self.analyze_swap_logic()
        pseudocode = self.generate_pseudocode(functions)

        report = {
            'summary': {
                'total_instructions': len(self.instructions),
                'function_calls': len(self.function_calls),
                'memory_operations': len(self.memory_operations),
                'constants': len(self.constants),
                'functions_identified': len(functions),
                'discriminators_found': len(discriminators)
            },
            'function_calls': {
                'count': len(self.function_calls),
                'unique_targets': len(set(fc['target'] for fc in self.function_calls)),
                'most_called': Counter(fc['target'] for fc in self.function_calls).most_common(10)
            },
            'memory_layout': {
                'stack_offsets': list(memory_map.keys())[:20],
                'total_unique_offsets': len(memory_map)
            },
            'control_flow': {
                jump_type: len(jumps) for jump_type, jumps in self.control_flow.items()
            },
            'potential_discriminators': [
                {'value': d['value'], 'addr': d['addr']}
                for d in discriminators[:10]
            ],
            'swap_patterns_found': len(swap_patterns),
            'functions': [
                {
                    'start': f['start'],
                    'end': f.get('end', 'unknown'),
                    'instruction_count': len(f['instructions'])
                }
                for f in functions[:10]
            ]
        }

        return report, pseudocode

    def save_results(self):
        """Save analysis results to files"""
        report, pseudocode = self.generate_report()

        # Save JSON report
        with open('lifinity_bytecode_analysis.json', 'w') as f:
            json.dump(report, f, indent=2)

        # Save pseudocode
        with open('lifinity_pseudocode.txt', 'w') as f:
            f.write("// Lifinity V2 - Extracted Pseudocode\n")
            f.write("// Generated from bytecode analysis\n\n")
            for code in pseudocode:
                f.write(code)

        print("\nAnalysis complete! Results saved to:")
        print("  - lifinity_bytecode_analysis.json")
        print("  - lifinity_pseudocode.txt")

        # Print summary
        print("\n" + "="*60)
        print("ANALYSIS SUMMARY")
        print("="*60)
        for key, value in report['summary'].items():
            print(f"{key:25}: {value}")

        print("\nTop 5 Most Called Functions:")
        for target, count in report['function_calls']['most_called'][:5]:
            print(f"  {target}: {count} calls")

        print("\nControl Flow Summary:")
        for jump_type, count in report['control_flow'].items():
            print(f"  {jump_type:10}: {count} occurrences")

if __name__ == "__main__":
    analyzer = LifinityBytecodeAnalyzer('/home/xnik/pepayPools/reverse-engineer-lifinity/lifinity_v2.disasm')
    analyzer.parse_disassembly()
    analyzer.save_results()