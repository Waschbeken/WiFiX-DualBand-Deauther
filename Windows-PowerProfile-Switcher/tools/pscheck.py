"""Grober Syntaxpruefer fuer PowerShell: entfernt Kommentare und Zeichenketten
und prueft danach Klammern sowie typische Zerstoerungsmuster."""
import sys, re

def strip(src):
    out, i, n = [], 0, len(src)
    line = 1
    while i < n:
        c = src[i]
        if c == '\n':
            line += 1; out.append(c); i += 1; continue
        # Blockkommentar
        if src.startswith('<#', i):
            j = src.find('#>', i + 2)
            j = n if j < 0 else j + 2
            line += src.count('\n', i, j); out.append('\n' * src.count('\n', i, j)); i = j; continue
        # Here-String
        if src.startswith("@'", i) or src.startswith('@"', i):
            q = src[i+1]
            end = "\n'@" if q == "'" else '\n"@'
            j = src.find(end, i + 2)
            j = n if j < 0 else j + len(end)
            out.append('\n' * src.count('\n', i, j) + 'S'); i = j; continue
        # Zeilenkommentar
        if c == '#':
            j = src.find('\n', i)
            i = n if j < 0 else j; continue
        # Einfache Anfuehrungszeichen
        if c == "'":
            j = i + 1
            while j < n:
                if src[j] == "'":
                    if j + 1 < n and src[j+1] == "'": j += 2; continue
                    j += 1; break
                j += 1
            out.append('\n' * src.count('\n', i, j) + 'S'); i = j; continue
        # Doppelte Anfuehrungszeichen (Backtick als Escape)
        if c == '"':
            j = i + 1
            while j < n:
                if src[j] == '`': j += 2; continue
                if src[j] == '"': j += 1; break
                j += 1
            out.append('\n' * src.count('\n', i, j) + 'S'); i = j; continue
        out.append(c); i += 1
    return ''.join(out)

def check(path):
    src = open(path, encoding='utf-8').read()
    code = strip(src)
    problems = []
    stack = []
    pairs = {'{': '}', '(': ')', '[': ']'}
    closing = {v: k for k, v in pairs.items()}
    line = 1
    for ch in code:
        if ch == '\n': line += 1
        elif ch in pairs: stack.append((ch, line))
        elif ch in closing:
            if not stack:
                problems.append(f"Zeile {line}: '{ch}' ohne oeffnende Klammer")
            elif stack[-1][0] != closing[ch]:
                o, ol = stack[-1]
                problems.append(f"Zeile {line}: '{ch}' passt nicht zu '{o}' aus Zeile {ol}")
                stack.pop()
            else:
                stack.pop()
    for o, ol in stack:
        problems.append(f"Zeile {ol}: '{o}' wird nie geschlossen")

    # Typische Zerstoerungsmuster durch fehlerhafte Textersetzung
    for i, l in enumerate(code.split('\n'), 1):
        if re.search(r'\}\s*catch\s*\{[^}]*\}\s*\|', l):
            problems.append(f"Zeile {i}: Pipe direkt hinter catch-Block")

    # "An empty pipe element is not allowed": ein '|' ohne Befehl davor oder
    # dahinter. Genau dieser Fehler ist beim Ausliefern schon einmal
    # durchgerutscht, deshalb wird er hier gezielt gesucht.
    lines = code.split('\n')
    n = len(code)
    line_of = []
    ln = 1
    for ch in code:
        line_of.append(ln)
        if ch == '\n': ln += 1
    for idx, ch in enumerate(code):
        if ch != '|':
            continue
        # Zeichen davor (Zeilenumbrueche mitzaehlen: eine Pipe darf nicht
        # als erstes Zeichen einer Anweisung stehen)
        j = idx - 1
        while j >= 0 and code[j] in ' \t': j -= 1
        prev = code[j] if j >= 0 else ''
        if prev in ('{', ';', '(', '|', '\n', ''):
            problems.append(f"Zeile {line_of[idx]}: leeres Pipe-Element (nichts vor '|')")
            continue
        # Zeichen danach, Zeilenumbrueche sind erlaubt (Fortsetzung)
        k = idx + 1
        while k < n and code[k] in ' \t\r\n': k += 1
        nxt = code[k] if k < n else ''
        if nxt in ('}', ')', ';', '|', ''):
            problems.append(f"Zeile {line_of[idx]}: leeres Pipe-Element (nichts nach '|')")
    return problems

rc = 0
for path in sys.argv[1:]:
    problems = check(path)
    name = path.split('/')[-1]
    if problems:
        rc = 1
        print(f"{name}:")
        for p in problems[:10]: print(f"   {p}")
    else:
        print(f"{name}: OK")
sys.exit(rc)
