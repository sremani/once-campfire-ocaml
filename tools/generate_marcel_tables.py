"""Convert the pinned Rust port's generated Marcel tables to an OCaml module.

The Rust tables were dumped from the reference Rails bundle's Marcel 1.1.0.
Pass the source `crates/storage/src/tables.rs` as the sole argument.
"""

import ast
import json
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text()
token = re.compile(r'\s*(?:(b?"(?:\\.|[^"\\])*")|([A-Za-z_][A-Za-z_0-9]*)|'
                   r'(&\[)|([\[\]{}(),:])|(\d+)|(.))', re.S)


class Parser:
    def __init__(self, text):
        self.tokens = []
        for match in token.finditer(text):
            quoted, word, arr, punctuation, number, error = match.groups()
            if error:
                raise ValueError(f"unexpected {error!r} near {match.start()}")
            self.tokens.append(word or arr or punctuation or number or quoted)
        self.at = 0

    def take(self, expected=None):
        result = self.tokens[self.at]
        self.at += 1
        if expected is not None and result != expected:
            raise ValueError(f"expected {expected!r}, got {result!r}")
        return result

    def peek(self):
        return self.tokens[self.at]

    def value(self):
        here = self.take()
        if here == '&[':
            values = []
            while self.peek() != ']':
                values.append(self.value())
                if self.peek() == ',':
                    self.take(',')
            self.take(']')
            return values
        if here == '(':
            values = []
            while self.peek() != ')':
                values.append(self.value())
                if self.peek() == ',':
                    self.take(',')
            self.take(')')
            return values
        if here == 'Match':
            self.take('{')
            obj = {}
            while self.peek() != '}':
                name = self.take()
                self.take(':')
                obj[name] = self.value()
                if self.peek() == ',':
                    self.take(',')
            self.take('}')
            return obj
        if here == 'Some':
            self.take('(')
            value = self.value()
            self.take(')')
            return value
        if here == 'None':
            return None
        if here[0] == '"' or here.startswith('b"'):
            value = ast.literal_eval(here)
            return value.hex() if isinstance(value, bytes) else value
        if here.isdigit():
            return int(here)
        raise ValueError(here)


tables = {}
for name in ('EXTENSIONS', 'TYPE_EXTS', 'TYPE_PARENTS', 'MAGIC'):
    start = source.index(f'pub static {name}:')
    start = source.index('= &', start) + 2
    parser = Parser(source[start:source.find('\n];', start) + 2])
    tables[name.lower()] = parser.value()

json_data = json.dumps(tables, ensure_ascii=False, separators=(',', ':'))
output = pathlib.Path('lib/storage_marcel_tables.ml')
output.write_text('(* Generated from pinned Marcel 1.1.0 tables via '
                  'tools/generate_marcel_tables.py. *)\n'
                  f'let json = {{marcel|{json_data}|marcel}}\n')
print(f'{output}: {len(json_data)} bytes')
