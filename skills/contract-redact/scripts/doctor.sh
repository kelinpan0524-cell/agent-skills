#!/usr/bin/env bash
# doctor.sh：检查 contract-redact 命令行、Python 版本、.doc 转换器与 OCR 引擎是否就绪（只读）。
set -uo pipefail

SELF_TEST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --self-test) SELF_TEST=1; shift ;;
    -h|--help)
      echo "用法：doctor.sh [--self-test]"
      exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

if [ "$SELF_TEST" = "1" ]; then
  bash -n "$0" || exit 1
  bash "$0" --help >/dev/null || exit 1
  echo "self-test OK：doctor.sh 语法与帮助检查通过"
  exit 0
fi

os_name="$(uname -s)"
missing=0

echo "== contract-redact 环境体检 ($os_name)"

if command -v contract-redact >/dev/null 2>&1; then
  cli_path="$(command -v contract-redact)"
  echo "✓ 命令行：contract-redact ($cli_path)"
  if contract-redact --help >/dev/null 2>&1; then
    echo "✓ 帮助命令可正常执行"
  else
    echo "✗ contract-redact --help 执行失败，请重装" >&2
    missing=1
  fi
elif [ -f "./redact_cli.py" ]; then
  echo "✓ 源码入口：当前目录存在 ./redact_cli.py"
else
  echo "✗ 未找到 contract-redact 命令"
  echo "  安装建议：pipx install git+https://github.com/kelinpan0524-cell/contract-redact"
  missing=1
fi

if command -v python3 >/dev/null 2>&1; then
  py_ver="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
  py_ok="$(python3 -c 'import sys; print(1 if sys.version_info >= (3, 10) else 0)')"
  if [ "$py_ok" = "1" ]; then
    echo "✓ Python：$py_ver"
  else
    echo "✗ Python 版本为 ${py_ver}，需要 >= 3.10"
    missing=1
  fi
else
  echo "✗ 未找到 python3"
  missing=1
fi

# 检查 .doc 转换器（仅旧版 .doc 需要）
if [ "$os_name" = "Darwin" ]; then
  command -v textutil >/dev/null 2>&1 && echo "✓ .doc 转换：textutil（系统自带）" || echo "! 未见 textutil（仅处理 .doc 时受影响）"
else
  if command -v soffice >/dev/null 2>&1 || command -v libreoffice >/dev/null 2>&1; then
    echo "✓ .doc 转换：LibreOffice"
  else
    echo "! 未见 LibreOffice（仅处理旧版 .doc 时需要；docx/pdf/xlsx 不受影响）"
  fi
fi

# 检查 OCR（优先探测 contract-redact 所在 Python 环境）
ocr_py="python3"
if command -v contract-redact >/dev/null 2>&1; then
  shebang_line="$(head -n 1 "$(command -v contract-redact)" 2>/dev/null || true)"
  case "$shebang_line" in
    "#!/"*"/env "*)
      shebang_py="$(printf '%s\n' "$shebang_line" | awk '{print $2}')" ;;
    "#!"*)
      shebang_py="$(printf '%s\n' "$shebang_line" | sed 's/^#!//' | awk '{print $1}')" ;;
    *)
      shebang_py="" ;;
  esac
  if [ -n "$shebang_py" ] && command -v "$shebang_py" >/dev/null 2>&1; then
    ocr_py="$shebang_py"
  fi
fi

if [ "$os_name" = "Darwin" ]; then
  if "$ocr_py" -c "import Vision" >/dev/null 2>&1; then
    echo "✓ 扫描件 OCR：macOS Vision 可用"
  else
    echo "! 扫描件 OCR：Vision 框架未在 $ocr_py 中就绪（仅扫描版 PDF 需要）"
    echo "  补装命令：pipx inject contract-redact pyobjc-framework-Vision pyobjc-framework-Quartz"
  fi
else
  if "$ocr_py" -c "import rapidocr_onnxruntime" >/dev/null 2>&1; then
    echo "✓ 扫描件 OCR：rapidocr-onnxruntime 可用"
  else
    echo "! 扫描件 OCR：未装 rapidocr-onnxruntime（仅扫描版 PDF 需要）"
    echo "  补装命令：pipx inject contract-redact rapidocr-onnxruntime"
  fi
fi

exit "$missing"
