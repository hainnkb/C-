input_file = "log.txt"
output_file = "fail_access_policy.txt"

fails_after_access_policy = []
in_access_policy = False
last_access_policy_line = ""

with open(input_file, "r", encoding="utf-8") as f:
    for i, line in enumerate(f, start=1):
        s = line.strip()

        if "Read check" in s:
            in_access_policy = False
            last_access_policy_line = ""

        elif "Access Policy" in s:
            in_access_policy = True
            last_access_policy_line = f"Line {i}: {line}"
            if "FAIL" in s:
                fails_after_access_policy.append(last_access_policy_line)

        elif in_access_policy and s == "FAIL":
            if last_access_policy_line:
                fails_after_access_policy.append(last_access_policy_line)
            fails_after_access_policy.append(f"Line {i}: {line}")
            last_access_policy_line = ""

with open(output_file, "w", encoding="utf-8") as f:
    f.writelines(fails_after_access_policy)

print(f"Đã ghi {len(fails_after_access_policy)} dòng vào file {output_file}")
