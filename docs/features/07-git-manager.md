# Tính năng 7 — Git Manager (repo + auto-scan + merge MR/PR)

## Mục tiêu
Màn hình danh sách Git repo (local + remote), auto-scan định kỳ, phát hiện Merge Request (GitLab) / Pull Request (GitHub), và **merge trực tiếp** từ app.

## Kiến trúc 2 lớp + 1 lớp nối

```
LocalRepoScanner  ──┐
                    ├─> RepoCorrelator (origin URL → provider)
GitHostProvider ────┘
   ├─ GitHubProvider   (Pull Request)
   └─ GitLabProvider   (Merge Request)
```

## Lớp local — `LocalRepoScanner`
- Quét folder gốc tìm `.git`; mỗi repo: `git fetch`, đọc branch, ahead/behind, dirty/clean.
- `git remote get-url origin` → nối repo local với MR/PR remote.
- Cách làm: **shell ra `git` CLI** qua `Process` (nhẹ nhất; cần Xcode Command Line Tools). Thay thế: `SwiftGit2` (libgit2) nếu muốn in-process.

> **Lưu ý quan trọng (đã làm rõ):** git CLI **lấy được code/ref** của PR/MR (`refs/pull/*/head` cho GitHub, `refs/merge-requests/*/head` cho GitLab qua `git ls-remote`/`git fetch`), **nhưng KHÔNG** lấy được metadata (title, author, CI, mergeable) và **KHÔNG** thực hiện được hành động "merge" đúng nghĩa nền tảng. → Phần đó bắt buộc dùng API.

## Lớp remote — `GitHostProvider` (protocol chung)
Dùng `URLSession` async + `Codable` (không cần SDK nặng). Token (PAT) lưu **Keychain**.

| Việc | GitHub | GitLab |
|------|--------|--------|
| List | `GET /repos/{owner}/{repo}/pulls?state=open` | `GET /projects/{id}/merge_requests?state=opened` |
| Mergeable / CI | field `mergeable`,`mergeable_state`; Checks API `GET /commits/{ref}/check-runs` | field `pipeline`; `GET /projects/{id}/pipelines` |
| **Merge** | `PUT /repos/{owner}/{repo}/pulls/{number}/merge` (`merge_method`=merge\|squash\|rebase) | `PUT /projects/{id}/merge_requests/{iid}/merge` (`squash`, `merge_when_pipeline_succeeds`) |
| Method cho phép | `allow_squash_merge`/`allow_merge_commit`/`allow_rebase_merge` | `merge_method` của project |

## Kiểu merge (đề xuất đã chốt: để Claude đề xuất)
- **Mặc định: Squash** (lịch sử main sạch).
- **Tôn trọng cấu hình repo/project**: chỉ hiện method nền tảng cho phép → tránh gọi method bị cấm.
- Cho **chọn lại từng lần** (dropdown), mặc định squash.
- **Bắt buộc xác nhận**: hiển thị source → target branch, trạng thái CI, có conflict không, trước khi merge.

## Auto-scan & rate limit
- `DispatchSourceTimer` / async loop, chu kỳ cấu hình (gợi ý ≥ 60s), **stagger** giữa các repo (không poll dồn).
- **GitHub:** dùng `If-None-Match` (ETag); **[Unverified, theo tài liệu]** response 304 không tính vào rate limit (5000 req/giờ authenticated). Cache ETag từng endpoint.
- **GitLab:** dùng conditional request tương tự; rate limit tùy cloud/self-host.

## Rủi ro & lưu ý
- ⚠️ Merge remote **khó hoàn tác** → luôn xác nhận; hiển thị rõ branch + CI.
- **[Inference]** Merge local rồi push thẳng có thể bị chặn bởi protected branch và bỏ qua tùy chọn nền tảng → ưu tiên merge qua API.
- **Sleep/wake:** dừng timer khi sleep, resume + scan lại khi wake; mọi call có timeout.

## Task

| ID | Task | Trạng thái | Ghi chú |
|----|------|-----------|---------|
| GIT-01 | `LocalRepoScanner`: quét `.git`, đọc branch/ahead-behind | ⬜ TODO | |
| GIT-02 | `git fetch` định kỳ + parse status | ⬜ TODO | |
| GIT-03 | `RepoCorrelator`: parse origin URL → host+owner/repo | ⬜ TODO | |
| GIT-04 | Protocol `GitHostProvider` chung | ⬜ TODO | |
| GIT-05 | `GitHubProvider`: list PR + mergeable + CI | ⬜ TODO | |
| GIT-06 | `GitHubProvider`: merge (merge/squash/rebase) | ⬜ TODO | |
| GIT-07 | `GitLabProvider`: list MR + pipeline | ⬜ TODO | |
| GIT-08 | `GitLabProvider`: merge (+squash, when pipeline succeeds) | ⬜ TODO | |
| GIT-09 | Lưu PAT vào Keychain (GitHub + GitLab) | ⬜ TODO | |
| GIT-10 | Auto-scan timer + ETag/conditional request | ⬜ TODO | |
| GIT-11 | UI master-detail: list repo (badge MR/PR + CI) + chi tiết | ⬜ TODO | |
| GIT-12 | Dialog xác nhận merge (branch, CI, conflict, chọn method) | ⬜ TODO | |
| GIT-13 | Chỉ hiện method merge nền tảng cho phép | ⬜ TODO | |
| GIT-14 | Xử lý sleep/wake + timeout cho mọi network call | ⬜ TODO | |
