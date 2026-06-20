#!/bin/bash
# Vá thread-safety cho RoyalVNCKit qua fork của bạn.
#
# Bước 1 (làm 1 lần, trên web): mở https://github.com/royalapplications/royalvnc
#   → bấm "Fork" về tài khoản của bạn (vd github.com/xuanha31/royalvnc).
# Bước 2: chạy script này với URL fork:
#   ./scripts/setup-royalvnc-fork.sh https://github.com/xuanha31/royalvnc.git
#
# Script clone fork → tạo branch threadsafe-queue từ tag 1.0.0 → áp patch
# docs/patches/royalvnc-queue-threadsafe.patch → commit → push.
# Sau đó báo lại để cập nhật Package.swift pin sang branch này.
set -e

FORK_URL="${1:?Cần URL fork, vd: https://github.com/xuanha31/royalvnc.git}"
UPSTREAM="https://github.com/royalapplications/royalvnc.git"
BASE_SHA="60a92e1a60e928b29c16230598efd5a97c134139"  # tag 1.0.0
BRANCH="threadsafe-queue"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCH="${ROOT}/docs/patches/royalvnc-queue-threadsafe.patch"
TMP="$(mktemp -d)"

echo "▶ Clone fork…"
git clone "$FORK_URL" "$TMP/royalvnc"
cd "$TMP/royalvnc"

echo "▶ Lấy commit 1.0.0 (${BASE_SHA:0:7}) từ upstream…"
git remote add upstream "$UPSTREAM"
git fetch --depth 1 upstream "$BASE_SHA"

echo "▶ Tạo branch ${BRANCH} từ 1.0.0…"
git checkout -b "$BRANCH" "$BASE_SHA"

echo "▶ Áp patch…"
git apply "$PATCH"
git add Sources/RoyalVNCKit/Extensions/Queue.swift
git commit -m "Make Queue thread-safe (NSLock) — fix input/send-loop data race"

echo "▶ Push…"
git push -u origin "$BRANCH"

echo "✓ Đã push branch '${BRANCH}' lên ${FORK_URL}"
echo "  → Báo lại để cập nhật Package.swift pin sang fork branch này."
