import Foundation

/// The GitHub tools, run on this phone against the REST API with the user's own token.
/// Schemas are in `LiveToolSchemas`, named after GitHub's MCP tools with a `github_` prefix.
enum GitHubTools {
    static let prefix = "github_"

    static let readTools: [String] = [
        "github_get_me", "github_search_repositories", "github_list_pull_requests", "github_pull_request_read",
        "github_search_pull_requests", "github_list_issues", "github_issue_read", "github_search_issues",
        "github_list_commits", "github_get_commit", "github_get_file_contents", "github_search_code",
        "github_actions_list", "github_actions_get", "github_get_job_logs", "github_list_notifications",
        "github_get_notification_details", "github_list_label",
    ]

    /// Five names, nine mutations between them. Each is gated by the GitHub skill's two-turn
    /// confirm, except `update_pull_request`, where only `base` is.
    static let writeTools: [String] = [
        "github_merge_pull_request", "github_issue_write", "github_add_issue_comment",
        "github_update_pull_request", "github_actions_run_trigger",
    ]

    /// ALLOWED_TOOLS: the write boundary. The `repo` scope carries push, force-push and delete, so
    /// what this connector can do is this list, not the grant. Nothing outside it runs.
    static let allowedTools: Set<String> = Set(readTools + writeTools)

    static func isGitHubTool(_ name: String) -> Bool { name.hasPrefix(prefix) }

    // MARK: - Session setup

    /// The schemas, with an `account` parameter only when more than one login is connected.
    static func definitions(logins: [String], catalog: LiveSessionSetup.Catalog) -> [[String: Any]] {
        guard !logins.isEmpty else { return [] }
        return (readTools + writeTools).compactMap { name in
            var tool = catalog.tool(name)
            guard !tool.isEmpty else { return nil }
            if logins.count > 1, var parameters = tool["parameters"] as? [String: Any] {
                var properties = parameters["properties"] as? [String: Any] ?? [:]
                properties["account"] = [
                    "type": "string",
                    "description": "Which GitHub login to use. Connected: \(logins.joined(separator: ", ")). "
                        + "Omit to use \(logins[0]).",
                ]
                parameters["properties"] = properties
                tool["parameters"] = parameters
            }
            return tool
        }
    }

    // MARK: - Run

    /// Never throws: a refusal or failure comes back as text the model can say.
    static func run(name: String, argumentsJSON: String,
                    accounts: [GitHubAccountStore.Account] = GitHubAccountStore.usable(),
                    makeAPI: (String, Bool) -> GitHubAPI = { GitHubAPI(token: $0, allowWrites: $1) }) async -> FullDuplexBroker.ToolResult {
        guard allowedTools.contains(name), let handler = handlers[name] else {
            RealtimeLog.log("github: \(name) refused — not in ALLOWED_TOOLS")
            return .init(text: "\(name) is not a GitHub tool this app allows. Say plainly what you can do on GitHub instead.", ok: false)
        }
        guard !accounts.isEmpty else {
            return .init(text: "No GitHub account is connected. Ask the user to connect GitHub in Settings.", ok: false)
        }
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let account = accountFor(accounts, args)
        let isWrite = writeTools.contains(name)
        let started = Date()
        do {
            let result = try await handler(makeAPI(account.token, isWrite), args)
            RealtimeLog.log("github: @\(account.login) \(name) ok in \(Int(Date().timeIntervalSince(started) * 1000))ms")
            if isWrite {
                let receipt = receipt(name, result)
                return .init(text: receipt.text, ok: receipt.ok, performedTool: receipt.ok ? name : nil)
            }
            return .init(text: encode(result), ok: true)
        } catch {
            let status = (error as? GitHubAPI.Failure)?.status
            RealtimeLog.log("github: @\(account.login) \(name) failed — \(status.map { "HTTP \($0)" } ?? "network")")
            if status == 401 { GitHubAccountStore.markNeedsReauth(token: account.token) }
            return .init(text: GitHubAPI.explain(error), ok: false)
        }
    }

    /// First connected unless `account` names another. An unknown name falls back to the first:
    /// an answer from the account that is connected beats an error about a parameter.
    static func accountFor(_ accounts: [GitHubAccountStore.Account], _ args: [String: Any]) -> GitHubAccountStore.Account {
        let named = str(args, "account").lowercased()
        return accounts.first { !named.isEmpty && $0.login.lowercased() == named } ?? accounts[0]
    }

    typealias Handler = (GitHubAPI, [String: Any]) async throws -> [String: Any]

    static let handlers: [String: Handler] = [
        "github_get_me": getMe,
        "github_search_repositories": searchRepositories,
        "github_list_pull_requests": listPullRequests,
        "github_pull_request_read": pullRequestRead,
        "github_search_pull_requests": { try await searchIssuesOrPulls($0, $1, kind: "pr") },
        "github_list_issues": listIssues,
        "github_issue_read": issueRead,
        "github_search_issues": { try await searchIssuesOrPulls($0, $1, kind: "issue") },
        "github_list_commits": listCommits,
        "github_get_commit": getCommit,
        "github_get_file_contents": getFileContents,
        "github_search_code": searchCode,
        "github_actions_list": actionsList,
        "github_actions_get": actionsGet,
        "github_get_job_logs": getJobLogs,
        "github_list_notifications": listNotifications,
        "github_get_notification_details": getNotificationDetails,
        "github_list_label": listLabel,
        "github_merge_pull_request": mergePullRequest,
        "github_issue_write": issueWrite,
        "github_add_issue_comment": addIssueComment,
        "github_update_pull_request": updatePullRequest,
        "github_actions_run_trigger": actionsRunTrigger,
    ]

    // MARK: - Receipts

    /// Writes answer in a sentence, keyed on the field that says GitHub did it: a declined merge
    /// is a 200 with `merged: false`.
    static func receipt(_ name: String, _ r: [String: Any]) -> (text: String, ok: Bool) {
        let repo = r["repo"] as? String ?? ""
        switch name {
        case "github_merge_pull_request":
            return r["merged"] as? Bool == true
                ? ("Merged \(repo) #\(r["pull_number"] ?? "") as \(r["sha"] ?? "").", true)
                : ("NOT MERGED — GitHub refused: \(r["message"] as? String ?? "no reason given").", false)
        case "github_issue_write":
            let issue = r["issue"] as? [String: Any] ?? [:]
            let number = issue["number"].map { "\($0)" } ?? "?"
            return r["created"] as? Bool == true
                ? ("Filed \(repo) #\(number): \(issue["title"] as? String ?? "").", true)
                : ("Updated \(repo) #\(number) — now \(issue["state"] as? String ?? "unknown").", true)
        case "github_add_issue_comment":
            return ("Commented on \(repo) #\(r["issue_number"] ?? "").", true)
        case "github_update_pull_request":
            let pull = r["pull_request"] as? [String: Any] ?? [:]
            let changed = (r["updated"] as? [String] ?? []).joined(separator: ", ")
            let notified = r["notified"] as? [String] ?? []
            return ("Updated \(repo) #\(pull["number"] ?? "") (\(changed)) — now \(pull["state"] as? String ?? "unknown")."
                + (notified.isEmpty ? "" : " Reviewers notified: \(notified.joined(separator: ", "))."), true)
        case "github_actions_run_trigger":
            if let workflow = r["dispatched"] as? String {
                return ("Started \(workflow) on \(r["ref"] ?? "") in \(repo). GitHub returns no run id on dispatch — "
                    + "list workflow runs to find it.", true)
            }
            return ("Done: \(r["action"] ?? "") on run \(r["run_id"] ?? "") in \(repo).", true)
        default:
            return (encode(r), true)
        }
    }

    // MARK: - Reads

    static func getMe(_ api: GitHubAPI, _ args: [String: Any]) async throws -> [String: Any] {
        let user = try await api.object("/user")
        return clean(["login": user["login"], "name": user["name"], "id": user["id"]])
    }

    static func searchRepositories(_ api: GitHubAPI, _ args: [String: Any]) async throws -> [String: Any] {
        let query = try required(args, "query", "A search query is required.")
        let data = try await api.object("/search/repositories", ["q": query, "per_page": perPage(args), "page": int(args, "page")])
        return ["total": data["total_count"] ?? 0, "repos": items(data).map(renderRepo)]
    }

    static func searchCode(_ api: GitHubAPI, _ args: [String: Any]) async throws -> [String: Any] {
        let query = try required(args, "query", "A search query is required.")
        let data = try await api.object("/search/code", ["q": query, "per_page": perPage(args), "page": int(args, "page")])
        return ["total": data["total_count"] ?? 0, "matches": items(data).map {
            clean(["path": $0["path"], "repo": ($0["repository"] as? [String: Any])?["full_name"]])
        }]
    }

    static func searchIssuesOrPulls(_ api: GitHubAPI, _ args: [String: Any], kind: String) async throws -> [String: Any] {
        let query = try required(args, "query", "A search query is required.")
        let q = query.range(of: #"\bis:(pr|issue)\b"#, options: .regularExpression) == nil ? "\(query) is:\(kind)" : query
        let data = try await api.object("/search/issues", ["q": q, "sort": str(args, "sort"), "order": str(args, "order"),
                                                           "per_page": perPage(args), "page": int(args, "page")])
        let found = items(data)
        return kind == "pr"
            ? ["total": data["total_count"] ?? 0, "pull_requests": found.map(renderPull)]
            : ["total": data["total_count"] ?? 0, "issues": found.map(renderIssue)]
    }

    static func listPullRequests(_ api: GitHubAPI, _ args: [String: Any]) async throws -> [String: Any] {
        let (owner, repo) = try repoPair(args)
        let pulls = try await api.list("/repos/\(owner)/\(repo)/pulls", [
            "state": str(args, "state").isEmpty ? "open" : str(args, "state"), "head": str(args, "head"),
            "base": str(args, "base"), "sort": str(args, "sort"), "direction": str(args, "direction"),
            "per_page": perPage(args), "page": int(args, "page"),
        ])
        return ["repo": "\(owner)/\(repo)", "pull_requests": pulls.map(renderPull)]
    }

    static func pullRequestRead(_ api: GitHubAPI, _ args: [String: Any]) async throws -> [String: Any] {
        let (owner, repo) = try repoPair(args)
        let number = try issueNumber(args, "pull_number")
        let base = "/repos/\(owner)/\(repo)/pulls/\(number)"
        let whereAt: [String: Any] = ["repo": "\(owner)/\(repo)", "pull_number": number]
        let method = str(args, "method").isEmpty ? "get" : str(args, "method")
        switch method {
        case "get":
            return ["repo": "\(owner)/\(repo)", "pull_request": renderPullDetail(try await api.object(base))]
        case "get_diff":
            let diff = try await api.text(base, accept: "application/vnd.github.diff")
            guard diff.count > maxDiff else { return whereAt.merging(["truncated": false, "diff": diff]) { $1 } }
            var cut = String(diff.prefix(maxDiff))
            if let newline = cut.lastIndex(of: "\n") { cut = String(cut[..<newline]) }
            return whereAt.merging(["truncated": true, "diff": cut,
                "note": "Diff cut at \(maxDiff) characters of \(diff.count). Use method get_files for the full list of what changed."]) { $1 }
        case "get_status":
            let pull = try await api.object(base)
            let sha = (pull["head"] as? [String: Any])?["sha"] as? String ?? ""
            async let combined = api.object("/repos/\(owner)/\(repo)/commits/\(sha)/status")
            async let checks = api.object("/repos/\(owner)/\(repo)/commits/\(sha)/check-runs", ["per_page": 50])
            let runs = (try await checks["check_runs"] as? [[String: Any]] ?? []).map {
                clean(["name": $0["name"], "status": $0["status"], "conclusion": $0["conclusion"]])
            }
            let state = try await combined["state"] as? String
            return whereAt.merging(clean([
                "head_sha": String(sha.prefix(7)), "state": worstOf(combined: state, checks: runs),
                "combined_state": state, "checks": runs,
                "mergeable": pull["mergeable"], "mergeable_state": pull["mergeable_state"],
            ])) { $1 }
        case "get_files":
            let files = try await api.list("\(base)/files", ["per_page": perPage(args, fallback: 100), "page": int(args, "page")])
            return whereAt.merging(["files": files.map {
                clean(["path": $0["filename"], "status": $0["status"], "additions": $0["additions"], "deletions": $0["deletions"]])
            }]) { $1 }
        case "get_reviews":
            return whereAt.merging(["reviews": try await api.list("\(base)/reviews").map(renderReview)]) { $1 }
        case "get_review_comments":
            let comments = try await api.list("\(base)/comments", ["per_page": perPage(args)])
            return whereAt.merging(["review_comments": comments.map(renderComment)]) { $1 }
        case "get_comments":
            let comments = try await api.list("/repos/\(owner)/\(repo)/issues/\(number)/comments", ["per_page": perPage(args)])
            return whereAt.merging(["comments": comments.map(renderComment)]) { $1 }
        default:
            throw GitHubAPI.Failure(status: 400, message: "Unknown method \"\(method)\". Use get, get_diff, get_status, "
                + "get_files, get_reviews, get_review_comments or get_comments.")
        }
    }

    /// One word for "do the checks pass", from the combined status and the check runs together.
    static func worstOf(combined: String?, checks: [[String: Any]]) -> String {
        let conclusions = checks.map { $0["conclusion"] as? String }
        if conclusions.contains(where: { $0 == "failure" || $0 == "timed_out" }) { return "failure" }
        if checks.contains(where: { $0["status"] as? String != "completed" }) { return "pending" }
        if conclusions.contains("cancelled") { return "cancelled" }
        if combined == "failure" || combined == "error" { return "failure" }
        if combined == "pending" && checks.isEmpty { return "pending" }
        return !checks.isEmpty || combined == "success" ? "success" : "unknown"
    }

    static func listIssues(_ api: GitHubAPI, _ args: [String: Any]) async throws -> [String: Any] {
        let (owner, repo) = try repoPair(args)
        let issues = try await api.list("/repos/\(owner)/\(repo)/issues", [
            "state": str(args, "state").isEmpty ? "open" : str(args, "state"), "labels": str(args, "labels"),
            "assignee": str(args, "assignee"), "creator": str(args, "creator"), "since": str(args, "since"),
            "sort": str(args, "sort"), "direction": str(args, "direction"),
            "per_page": perPage(args), "page": int(args, "page"),
        ])
        // The issues endpoint returns pull requests too.
        return ["repo": "\(owner)/\(repo)", "issues": issues.filter { $0["pull_request"] == nil }.map(renderIssue)]
    }

    static func issueRead(_ api: GitHubAPI, _ args: [String: Any]) async throws -> [String: Any] {
        let (owner, repo) = try repoPair(args)
        let number = try issueNumber(args, "issue_number")
        let base = "/repos/\(owner)/\(repo)/issues/\(number)"
        let whereAt: [String: Any] = ["repo": "\(owner)/\(repo)", "issue_number": number]
        let method = str(args, "method").isEmpty ? "get" : str(args, "method")
        switch method {
        case "get":
            let issue = try await api.object(base)
            return whereAt.merging(["issue": renderIssue(issue).merging(["body": clip(str(issue, "body"), 4_000)]) { $1 }]) { $1 }
        case "get_comments":
            let comments = try await api.list("\(base)/comments", ["per_page": perPage(args)])
            return whereAt.merging(["comments": comments.map(renderComment)]) { $1 }
        case "get_labels":
            return whereAt.merging(["labels": labelNames(try await api.list("\(base)/labels"))]) { $1 }
        case "get_sub_issues":
            let subs = try await api.list("\(base)/sub_issues", ["per_page": perPage(args)])
            return whereAt.merging(["sub_issues": subs.map(renderIssue)]) { $1 }
        default:
            throw GitHubAPI.Failure(status: 400, message: "Unknown method \"\(method)\". Use get, get_comments, get_labels or get_sub_issues.")
        }
    }

    static func listCommits(_ api: GitHubAPI, _ args: [String: Any]) async throws -> [String: Any] {
        let (owner, repo) = try repoPair(args)
        let sha = str(args, "sha").isEmpty ? str(args, "ref") : str(args, "sha")
        let commits = try await api.list("/repos/\(owner)/\(repo)/commits", [
            "sha": sha, "path": str(args, "path"), "author": str(args, "author"), "since": str(args, "since"),
            "until": str(args, "until"), "per_page": perPage(args), "page": int(args, "page"),
        ])
        return ["repo": "\(owner)/\(repo)", "commits": commits.map(renderCommit)]
    }

    static func getCommit(_ api: GitHubAPI, _ args: [String: Any]) async throws -> [String: Any] {
        let (owner, repo) = try repoPair(args)
        let sha = str(args, "sha").isEmpty ? str(args, "ref") : str(args, "sha")
        guard !sha.isEmpty else { throw GitHubAPI.Failure(status: 400, message: "A commit sha or ref is required.") }
        let c = try await api.object("/repos/\(owner)/\(repo)/commits/\(GitHubAPI.segment(sha))")
        let stats = c["stats"] as? [String: Any] ?? [:]
        var commit = renderCommit(c)
        commit["message"] = clip(str(c["commit"] as? [String: Any] ?? [:], "message"), 2_000)
        commit["additions"] = stats["additions"]
        commit["deletions"] = stats["deletions"]
        commit["files"] = (c["files"] as? [[String: Any]] ?? []).map {
            clean(["path": $0["filename"], "status": $0["status"], "additions": $0["additions"], "deletions": $0["deletions"]])
        }
        return ["repo": "\(owner)/\(repo)", "commit": clean(commit)]
    }

    static func getFileContents(_ api: GitHubAPI, _ args: [String: Any]) async throws -> [String: Any] {
        let (owner, repo) = try repoPair(args)
        let path = str(args, "path").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encoded = path.split(separator: "/").map { GitHubAPI.segment(String($0)) }.joined(separator: "/")
        let data = try await api.json("/repos/\(owner)/\(repo)/contents/\(encoded)", ["ref": str(args, "ref")])
        if let entries = data as? [[String: Any]] {
            return ["repo": "\(owner)/\(repo)", "path": path.isEmpty ? "/" : path,
                    "directory": entries.map { clean(["name": $0["name"], "type": $0["type"], "size": $0["size"]]) }]
        }
        let file = data as? [String: Any] ?? [:]
        guard file["encoding"] as? String == "base64" else {
            throw GitHubAPI.Failure(status: 415, message: "That file is \(file["encoding"] as? String ?? "not text") and "
                + "cannot be read aloud. Its size is \(file["size"] ?? "unknown") bytes.")
        }
        let raw = (file["content"] as? String ?? "").replacingOccurrences(of: "\n", with: "")
        guard let bytes = Data(base64Encoded: raw), !bytes.contains(0), let text = String(data: bytes, encoding: .utf8) else {
            throw GitHubAPI.Failure(status: 415, message: "That file is binary and cannot be read aloud.")
        }
        return clean(["repo": "\(owner)/\(repo)", "path": file["path"], "size": file["size"],
                      "sha": (file["sha"] as? String).map { String($0.prefix(7)) }, "content": clip(text, 20_000)])
    }

    static func listLabel(_ api: GitHubAPI, _ args: [String: Any]) async throws -> [String: Any] {
        let (owner, repo) = try repoPair(args)
        let labels = try await api.list("/repos/\(owner)/\(repo)/labels", ["per_page": perPage(args, fallback: 100)])
        return ["repo": "\(owner)/\(repo)", "labels": labels.map {
            clean(["name": $0["name"], "description": clip(str($0, "description"), 160)])
        }]
    }

    static func listNotifications(_ api: GitHubAPI, _ args: [String: Any]) async throws -> [String: Any] {
        let list = try await api.list("/notifications", [
            "all": args["all"] as? Bool == true ? "true" : nil,
            "participating": args["participating"] as? Bool == true ? "true" : nil,
            "since": str(args, "since"), "before": str(args, "before"),
            "per_page": perPage(args), "page": int(args, "page"),
        ])
        return ["notifications": list.map(renderNotification)]
    }

    static func getNotificationDetails(_ api: GitHubAPI, _ args: [String: Any]) async throws -> [String: Any] {
        let id = str(args, "notification_id").isEmpty ? str(args, "thread_id") : str(args, "notification_id")
        guard !id.isEmpty else { throw GitHubAPI.Failure(status: 400, message: "A notification_id is required.") }
        return ["notification": renderNotification(try await api.object("/notifications/threads/\(GitHubAPI.segment(id))"))]
    }

    static func actionsList(_ api: GitHubAPI, _ args: [String: Any]) async throws -> [String: Any] {
        let (owner, repo) = try repoPair(args)
        let base = "/repos/\(owner)/\(repo)/actions"
        let whereAt: [String: Any] = ["repo": "\(owner)/\(repo)"]
        let method = str(args, "method").isEmpty ? "workflow_runs" : str(args, "method")
        switch method {
        case "workflows":
            let data = try await api.object("\(base)/workflows", ["per_page": perPage(args, fallback: 100)])
            return whereAt.merging(["workflows": (data["workflows"] as? [[String: Any]] ?? []).map {
                clean(["id": $0["id"], "name": $0["name"], "path": $0["path"], "state": $0["state"]])
            }]) { $1 }
        case "workflow_runs":
            let workflow = str(args, "workflow_id")
            let path = workflow.isEmpty ? "\(base)/runs" : "\(base)/workflows/\(GitHubAPI.segment(workflow))/runs"
            let data = try await api.object(path, [
                "branch": str(args, "branch"), "event": str(args, "event"), "status": str(args, "status"),
                "actor": str(args, "actor"), "per_page": perPage(args), "page": int(args, "page"),
            ])
            return whereAt.merging(["workflow_runs": (data["workflow_runs"] as? [[String: Any]] ?? []).map(renderRun)]) { $1 }
        case "workflow_jobs":
            guard let runId = int(args, "run_id") else {
                throw GitHubAPI.Failure(status: 400, message: "A run_id is required for workflow_jobs.")
            }
            let data = try await api.object("\(base)/runs/\(runId)/jobs",
                                            ["filter": str(args, "filter"), "per_page": perPage(args, fallback: 100)])
            return whereAt.merging(["run_id": runId, "jobs": (data["jobs"] as? [[String: Any]] ?? []).map(renderJob)]) { $1 }
        default:
            throw GitHubAPI.Failure(status: 400, message: "Unknown method \"\(method)\". Use workflows, workflow_runs or workflow_jobs.")
        }
    }

    static func actionsGet(_ api: GitHubAPI, _ args: [String: Any]) async throws -> [String: Any] {
        let (owner, repo) = try repoPair(args)
        let base = "/repos/\(owner)/\(repo)/actions"
        let whereAt: [String: Any] = ["repo": "\(owner)/\(repo)"]
        let method = str(args, "method").isEmpty ? "workflow_run" : str(args, "method")
        switch method {
        case "workflow_run":
            guard let runId = int(args, "run_id") else { throw GitHubAPI.Failure(status: 400, message: "A run_id is required.") }
            return whereAt.merging(["workflow_run": renderRun(try await api.object("\(base)/runs/\(runId)"))]) { $1 }
        case "workflow_run_usage":
            guard let runId = int(args, "run_id") else { throw GitHubAPI.Failure(status: 400, message: "A run_id is required.") }
            let usage = try await api.object("\(base)/runs/\(runId)/timing")
            return whereAt.merging(clean(["run_id": runId, "duration_ms": usage["run_duration_ms"]])) { $1 }
        case "job":
            guard let jobId = int(args, "job_id") else { throw GitHubAPI.Failure(status: 400, message: "A job_id is required.") }
            return whereAt.merging(["job": renderJob(try await api.object("\(base)/jobs/\(jobId)"))]) { $1 }
        default:
            throw GitHubAPI.Failure(status: 400, message: "Unknown method \"\(method)\". Use workflow_run, workflow_run_usage or job.")
        }
    }

    static func getJobLogs(_ api: GitHubAPI, _ args: [String: Any]) async throws -> [String: Any] {
        let (owner, repo) = try repoPair(args)
        let base = "/repos/\(owner)/\(repo)/actions"
        let lines = min(500, max(10, int(args, "tail_lines") ?? 120))
        if args["failed_only"] as? Bool == true {
            guard let runId = int(args, "run_id") else {
                throw GitHubAPI.Failure(status: 400, message: "A run_id is required when failed_only is set.")
            }
            let data = try await api.object("\(base)/runs/\(runId)/jobs", ["filter": "latest", "per_page": 100])
            let failed = (data["jobs"] as? [[String: Any]] ?? []).filter {
                guard let conclusion = $0["conclusion"] as? String else { return false }
                return conclusion != "success" && conclusion != "skipped"
            }
            guard !failed.isEmpty else {
                return ["repo": "\(owner)/\(repo)", "run_id": runId, "failed_jobs": [Any](), "note": "No job failed."]
            }
            var logs: [[String: Any]] = []
            for job in failed.prefix(3) {
                let id = GitHubDeviceFlow.number(job["id"]).map { Int($0) } ?? 0
                logs.append(clean(["job": job["name"], "job_id": id, "conclusion": job["conclusion"],
                                   "log": tail(try await api.text("\(base)/jobs/\(id)/logs", accept: "text/plain"), lines)]))
            }
            var out: [String: Any] = ["repo": "\(owner)/\(repo)", "run_id": runId, "failed_jobs": logs]
            if failed.count > 3 { out["note"] = "\(failed.count) jobs failed; showing 3." }
            return out
        }
        guard let jobId = int(args, "job_id") else {
            throw GitHubAPI.Failure(status: 400, message: "A job_id is required, or set failed_only with a run_id.")
        }
        return ["repo": "\(owner)/\(repo)", "job_id": jobId,
                "log": tail(try await api.text("\(base)/jobs/\(jobId)/logs", accept: "text/plain"), lines)]
    }

    /// A build log's answer is at its end; its start is the same setup steps every time.
    static func tail(_ text: String, _ lines: Int) -> String {
        let all = text.components(separatedBy: "\n")
        guard all.count > lines else { return text }
        return "… [\(all.count - lines) earlier lines omitted]\n" + all.suffix(lines).joined(separator: "\n")
    }

    // MARK: - Writes

    static func mergePullRequest(_ api: GitHubAPI, _ args: [String: Any]) async throws -> [String: Any] {
        let (owner, repo) = try repoPair(args)
        let number = try issueNumber(args, "pull_number")
        var body: [String: Any] = [:]
        for key in ["commit_title", "commit_message", "merge_method"] where !str(args, key).isEmpty { body[key] = str(args, key) }
        let result = try await api.json("/repos/\(owner)/\(repo)/pulls/\(number)/merge", method: "PUT", body: body) as? [String: Any] ?? [:]
        return clean(["merged": result["merged"] as? Bool == true, "repo": "\(owner)/\(repo)", "pull_number": number,
                      "sha": (result["sha"] as? String).map { String($0.prefix(7)) }, "message": result["message"]])
    }

    static func issueWrite(_ api: GitHubAPI, _ args: [String: Any]) async throws -> [String: Any] {
        let (owner, repo) = try repoPair(args)
        let method = str(args, "method").isEmpty ? "create" : str(args, "method")
        var body: [String: Any] = [:]
        if !str(args, "title").isEmpty { body["title"] = str(args, "title") }
        if args["body"] != nil { body["body"] = str(args, "body") }
        if let labels = args["labels"] as? [String] { body["labels"] = labels }
        if let assignees = args["assignees"] as? [String] { body["assignees"] = assignees }
        for key in ["state", "state_reason"] where !str(args, key).isEmpty { body[key] = str(args, key) }
        switch method {
        case "create":
            guard body["title"] != nil else { throw GitHubAPI.Failure(status: 400, message: "A title is required to file an issue.") }
            let issue = try await api.json("/repos/\(owner)/\(repo)/issues", method: "POST", body: body) as? [String: Any] ?? [:]
            return ["created": true, "repo": "\(owner)/\(repo)", "issue": renderIssue(issue)]
        case "update":
            let number = try issueNumber(args, "issue_number")
            let issue = try await api.json("/repos/\(owner)/\(repo)/issues/\(number)", method: "PATCH", body: body) as? [String: Any] ?? [:]
            return ["updated": true, "repo": "\(owner)/\(repo)", "issue": renderIssue(issue)]
        default:
            throw GitHubAPI.Failure(status: 400, message: "Unknown method \"\(method)\". Use create or update.")
        }
    }

    static func addIssueComment(_ api: GitHubAPI, _ args: [String: Any]) async throws -> [String: Any] {
        let (owner, repo) = try repoPair(args)
        let number = try issueNumber(args, "issue_number")
        let text = try required(args, "body", "A comment body is required.")
        let comment = try await api.json("/repos/\(owner)/\(repo)/issues/\(number)/comments", method: "POST",
                                         body: ["body": text]) as? [String: Any] ?? [:]
        return clean(["commented": true, "repo": "\(owner)/\(repo)", "issue_number": number, "comment_id": comment["id"]])
    }

    static func updatePullRequest(_ api: GitHubAPI, _ args: [String: Any]) async throws -> [String: Any] {
        let (owner, repo) = try repoPair(args)
        let number = try issueNumber(args, "pull_number")
        let path = "/repos/\(owner)/\(repo)/pulls/\(number)"
        var done: [String] = []
        var patch: [String: Any] = [:]
        for key in ["title", "state", "base"] where !str(args, key).isEmpty { patch[key] = str(args, key) }
        if args["body"] != nil { patch["body"] = str(args, "body") }
        if let modify = args["maintainer_can_modify"] as? Bool { patch["maintainer_can_modify"] = modify }
        var pull: [String: Any]?
        if !patch.isEmpty {
            pull = try await api.json(path, method: "PATCH", body: patch) as? [String: Any]
            done += patch.keys.sorted()
        }
        let draft = args["draft"] as? Bool
        if let draft {
            var node = pull?["node_id"] as? String ?? ""
            if node.isEmpty { node = try await api.object(path)["node_id"] as? String ?? "" }
            guard !node.isEmpty else { throw GitHubAPI.Failure(status: 500, message: "GitHub returned no node_id for that pull request.") }
            let mutation = draft
                ? "mutation($id: ID!) { convertPullRequestToDraft(input: { pullRequestId: $id }) { pullRequest { isDraft } } }"
                : "mutation($id: ID!) { markPullRequestReadyForReview(input: { pullRequestId: $id }) { pullRequest { isDraft } } }"
            try await api.graphql(mutation, variables: ["id": node])
            done.append(draft ? "draft" : "ready_for_review")
        }
        let reviewers = (args["reviewers"] as? [Any] ?? []).map { "\($0)" }
        if !reviewers.isEmpty {
            _ = try await api.json("\(path)/requested_reviewers", method: "POST", body: ["reviewers": reviewers])
            done.append("reviewers")
        }
        guard !done.isEmpty else {
            throw GitHubAPI.Failure(status: 400, message: "Nothing to change. Pass at least one of draft, title, body, state, base or reviewers.")
        }
        let after = draft == nil && reviewers.isEmpty && pull != nil ? pull! : try await api.object(path)
        var out: [String: Any] = ["updated": done, "repo": "\(owner)/\(repo)", "pull_request": renderPull(after)]
        if draft == false { out["notified"] = (after["requested_reviewers"] as? [[String: Any]] ?? []).compactMap(login) }
        return out
    }

    static func actionsRunTrigger(_ api: GitHubAPI, _ args: [String: Any]) async throws -> [String: Any] {
        let (owner, repo) = try repoPair(args)
        let base = "/repos/\(owner)/\(repo)/actions"
        let method = str(args, "method")
        switch method {
        case "run_workflow":
            let workflow = str(args, "workflow_id"), ref = str(args, "ref")
            guard !workflow.isEmpty else {
                throw GitHubAPI.Failure(status: 400, message: "A workflow_id is required — its file name or numeric id. "
                    + "Find it with github_actions_list method workflows.")
            }
            guard !ref.isEmpty else { throw GitHubAPI.Failure(status: 400, message: "A ref is required — the branch to run against.") }
            var body: [String: Any] = ["ref": ref]
            if let inputs = args["inputs"] as? [String: Any] { body["inputs"] = inputs }
            _ = try await api.json("\(base)/workflows/\(GitHubAPI.segment(workflow))/dispatches", method: "POST", body: body)
            return ["repo": "\(owner)/\(repo)", "dispatched": workflow, "ref": ref]
        case "rerun_workflow_run", "rerun_failed_jobs", "cancel_workflow_run", "delete_workflow_run_logs":
            guard let runId = int(args, "run_id") else {
                throw GitHubAPI.Failure(status: 400, message: "A run_id is required for \(method).")
            }
            let suffix = ["rerun_workflow_run": "rerun", "rerun_failed_jobs": "rerun-failed-jobs",
                          "cancel_workflow_run": "cancel", "delete_workflow_run_logs": "logs"][method]!
            _ = try await api.json("\(base)/runs/\(runId)/\(suffix)",
                                   method: method == "delete_workflow_run_logs" ? "DELETE" : "POST")
            return ["repo": "\(owner)/\(repo)", "run_id": runId, "action": method]
        default:
            throw GitHubAPI.Failure(status: 400, message: "Unknown method \"\(method)\". Use run_workflow, rerun_workflow_run, "
                + "rerun_failed_jobs, cancel_workflow_run or delete_workflow_run_logs.")
        }
    }

    // MARK: - Arguments

    static let maxDiff = 12_000

    static func str(_ args: [String: Any], _ key: String) -> String {
        (args[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func int(_ args: [String: Any], _ key: String) -> Int? {
        GitHubDeviceFlow.number(args[key]).map { Int($0.rounded()) }
    }

    static func perPage(_ args: [String: Any], fallback: Int = 20) -> Int {
        min(100, max(1, int(args, "per_page") ?? fallback))
    }

    static func required(_ args: [String: Any], _ key: String, _ message: String) throws -> String {
        let value = str(args, key)
        guard !value.isEmpty else { throw GitHubAPI.Failure(status: 400, message: message) }
        return value
    }

    /// The model's failure without an owner is to guess the user's own login, which 404s for every
    /// org repo and sounds like the repo doesn't exist.
    static func repoPair(_ args: [String: Any]) throws -> (String, String) {
        let owner = str(args, "owner"), repo = str(args, "repo")
        guard !owner.isEmpty, !repo.isEmpty else {
            throw GitHubAPI.Failure(status: 400, message: "Both owner and repo are required. Resolve the repository the "
                + "user named with github_search_repositories first and use the owner/repo from its full_name — never guess an owner.")
        }
        return (GitHubAPI.segment(owner), GitHubAPI.segment(repo))
    }

    static func issueNumber(_ args: [String: Any], _ field: String) throws -> Int {
        guard let n = int(args, field) ?? int(args, "pull_number") ?? int(args, "issue_number"), n > 0 else {
            throw GitHubAPI.Failure(status: 400, message: "A valid \(field) is required.")
        }
        return n
    }

    // MARK: - Rendering: only what a spoken answer uses

    static func clean(_ dict: [String: Any?]) -> [String: Any] {
        dict.compactMapValues { value in
            guard let value, !(value is NSNull) else { return nil }
            return value
        }
    }

    static func clip(_ text: String, _ max: Int) -> String {
        guard text.count > max else { return text }
        let cut = String(text.prefix(max))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > Int(Double(max) * 0.8) {
            return String(cut[..<space]) + "… [truncated]"
        }
        return cut + "… [truncated]"
    }

    static func day(_ value: Any?) -> String? { (value as? String).map { String($0.prefix(10)) } }
    static func login(_ user: Any?) -> String? { (user as? [String: Any])?["login"] as? String }
    static func items(_ data: [String: Any]) -> [[String: Any]] { data["items"] as? [[String: Any]] ?? [] }

    static func repoName(_ item: [String: Any]) -> String? {
        (item["repository_url"] as? String).map { $0.replacingOccurrences(of: "https://api.github.com/repos/", with: "") }
    }

    static func labelNames(_ labels: Any?) -> [String] {
        (labels as? [Any] ?? []).compactMap { ($0 as? String) ?? (($0 as? [String: Any])?["name"] as? String) }
    }

    static func renderPull(_ p: [String: Any]) -> [String: Any] {
        clean(["number": p["number"], "title": p["title"], "author": login(p["user"]),
               "state": p["draft"] as? Bool == true ? "draft" : p["state"] as? String, "merged": day(p["merged_at"]),
               "base": (p["base"] as? [String: Any])?["ref"], "head": (p["head"] as? [String: Any])?["ref"],
               "updated": day(p["updated_at"]), "repo": repoName(p)])
    }

    static func renderPullDetail(_ p: [String: Any]) -> [String: Any] {
        renderPull(p).merging(clean([
            "body": clip(str(p, "body"), 2_000), "commits": p["commits"], "changed_files": p["changed_files"],
            "additions": p["additions"], "deletions": p["deletions"], "mergeable": p["mergeable"],
            "mergeable_state": p["mergeable_state"], "labels": labelNames(p["labels"]),
            "reviewers": (p["requested_reviewers"] as? [Any] ?? []).compactMap(login),
        ])) { $1 }
    }

    static func renderIssue(_ i: [String: Any]) -> [String: Any] {
        clean(["number": i["number"], "title": i["title"], "author": login(i["user"]), "state": i["state"],
               "state_reason": i["state_reason"], "labels": labelNames(i["labels"]),
               "assignees": (i["assignees"] as? [Any] ?? []).compactMap(login), "comments": i["comments"],
               "updated": day(i["updated_at"]), "repo": repoName(i)])
    }

    static func renderComment(_ c: [String: Any]) -> [String: Any] {
        clean(["id": c["id"], "author": login(c["user"]), "at": day(c["created_at"]), "body": clip(str(c, "body"), 2_000),
               "path": c["path"], "line": c["path"] == nil ? nil : (c["line"] ?? c["original_line"])])
    }

    static func renderReview(_ r: [String: Any]) -> [String: Any] {
        clean(["author": login(r["user"]), "state": r["state"], "at": day(r["submitted_at"]), "body": clip(str(r, "body"), 1_000)])
    }

    static func renderRepo(_ r: [String: Any]) -> [String: Any] {
        clean(["full_name": r["full_name"], "description": clip(str(r, "description"), 300), "private": r["private"],
               "default_branch": r["default_branch"], "language": r["language"],
               "updated": day(r["pushed_at"] ?? r["updated_at"]), "open_issues": r["open_issues_count"]])
    }

    static func renderCommit(_ c: [String: Any]) -> [String: Any] {
        let commit = c["commit"] as? [String: Any] ?? [:]
        let author = commit["author"] as? [String: Any] ?? [:]
        let sha = c["sha"] as? String
        let subject = str(commit, "message").components(separatedBy: "\n").first ?? ""
        return clean(["sha": sha.map { String($0.prefix(7)) }, "full_sha": sha, "message": clip(subject, 200),
                      "author": login(c["author"]) ?? (author["name"] as? String), "at": day(author["date"])])
    }

    static func renderRun(_ r: [String: Any]) -> [String: Any] {
        clean(["id": r["id"], "name": r["name"] ?? r["display_title"], "workflow": r["path"], "branch": r["head_branch"],
               "event": r["event"], "status": r["status"], "conclusion": r["conclusion"], "attempt": r["run_attempt"],
               "number": r["run_number"], "started": r["run_started_at"] ?? r["created_at"], "updated": r["updated_at"]])
    }

    static func renderJob(_ j: [String: Any]) -> [String: Any] {
        let failed = (j["steps"] as? [[String: Any]] ?? []).filter {
            guard let conclusion = $0["conclusion"] as? String else { return false }
            return conclusion != "success" && conclusion != "skipped"
        }.map { clean(["name": $0["name"], "conclusion": $0["conclusion"], "number": $0["number"]]) }
        return clean(["id": j["id"], "name": j["name"], "status": j["status"], "conclusion": j["conclusion"],
                      "started": j["started_at"], "completed": j["completed_at"], "failed_steps": failed.isEmpty ? nil : failed])
    }

    static func renderNotification(_ n: [String: Any]) -> [String: Any] {
        let subject = n["subject"] as? [String: Any] ?? [:]
        let number = (subject["url"] as? String)?.split(separator: "/").last.flatMap { Int($0) }
        return clean(["id": n["id"], "reason": n["reason"], "unread": n["unread"], "title": subject["title"],
                      "type": subject["type"], "number": number,
                      "repo": (n["repository"] as? [String: Any])?["full_name"], "updated": n["updated_at"]])
    }

    static func encode(_ value: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
