fails_after_access_policy = []
in_access_policy = False

with open("log.txt", "r", encoding="utf-8") as f:
    for i, line in enumerate(f, start=1):
        s = line.strip()

        if "Access Policy" in s:
            in_access_policy = True
            continue

        if "Read check" in s:
            in_access_policy = False
            continue

        if in_access_policy and s == "FAIL":
            fails_after_access_policy.append((i, s))

print("Found FAIL after Access Policy:")
for line_no, text in fails_after_access_policy:
    print(f"Line {line_no}: {text}")
