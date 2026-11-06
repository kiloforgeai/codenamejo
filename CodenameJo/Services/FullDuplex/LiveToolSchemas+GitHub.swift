import Foundation

extension LiveToolSchemas {
    static let github: [[String: Any]] = [
        githubGetMe, githubSearchRepositories, githubListPullRequests, githubPullRequestRead,
        githubSearchPullRequests, githubListIssues, githubIssueRead, githubSearchIssues,
        githubListCommits, githubGetCommit, githubGetFileContents, githubSearchCode,
        githubActionsList, githubActionsGet, githubGetJobLogs, githubListNotifications,
        githubGetNotificationDetails, githubListLabel, githubMergePullRequest, githubIssueWrite,
        githubAddIssueComment, githubUpdatePullRequest, githubActionsRunTrigger,
    ]

    static let githubGetMe: [String: Any] = [
        "type": "function",
        "name": "github_get_me",
        "description": "The signed-in GitHub user — their login and name. Call this to resolve \"my\" in a question about pull requests, issues or reviews, rather than asking the user what their username is.",
        "parameters": [
            "type": "object",
            "properties": [String: Any](),
        ],
        "strict": false,
    ]

    static let githubSearchRepositories: [String: Any] = [
        "type": "function",
        "name": "github_search_repositories",
        "description": "Find a repository by name or description. This is what turns a repo the user said out loud — \"the voice app\", \"the broker\" — into the owner/repo pair every other GitHub tool needs. Call it first whenever you do not already have that pair; guessing an owner is the most common way a GitHub question fails.",
        "parameters": [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "GitHub search syntax. A bare name works; narrow with qualifiers like `user:kiloforgeai` or `org:kiloforgeai` when the user named a place.",
                ],
                "per_page": [
                    "type": "integer",
                    "description": "How many results, 1 to 100. Default 20.",
                ],
                "page": [
                    "type": "integer",
                    "description": "Page number, for more results.",
                ],
            ],
            "required": ["query"],
        ],
        "strict": false,
    ]

    static let githubListPullRequests: [String: Any] = [
        "type": "function",
        "name": "github_list_pull_requests",
        "description": "Open pull requests in one repository, newest activity first by default. Each comes back with its number, title, author, draft state, branches and the date it last moved. Use github_search_pull_requests instead when the question spans repos or asks about \"mine\".",
        "parameters": [
            "type": "object",
            "properties": [
                "owner": [
                    "type": "string",
                    "description": "The repository owner — the user or organization. Get it from github_search_repositories' full_name (owner/repo). Never guess it, and never assume the signed-in user owns the repo: most repos that matter live under an organization.",
                ],
                "repo": [
                    "type": "string",
                    "description": "The repository name alone, without the owner.",
                ],
                "state": [
                    "type": "string",
                    "enum": ["open", "closed", "all"],
                    "description": "Default open.",
                ],
                "base": [
                    "type": "string",
                    "description": "Only PRs targeting this branch.",
                ],
                "head": [
                    "type": "string",
                    "description": "Only PRs from this branch.",
                ],
                "sort": [
                    "type": "string",
                    "enum": ["created", "updated", "popularity", "long-running"],
                    "description": "Default created.",
                ],
                "direction": [
                    "type": "string",
                    "enum": ["asc", "desc"],
                ],
                "per_page": [
                    "type": "integer",
                    "description": "How many results, 1 to 100. Default 20.",
                ],
                "page": [
                    "type": "integer",
                    "description": "Page number, for more results.",
                ],
            ],
            "required": ["owner", "repo"],
        ],
        "strict": false,
    ]

    static let githubPullRequestRead: [String: Any] = [
        "type": "function",
        "name": "github_pull_request_read",
        "description": "Everything about one pull request, by method: `get` for its title, body, author and mergeability; `get_status` for whether its checks pass — use this before saying anything about CI; `get_files` for what changed; `get_diff` for the change itself (capped, so use get_files when you only need the file list); `get_reviews` for who approved or requested changes; `get_comments` for the discussion; `get_review_comments` for line-level notes on the code.",
        "parameters": [
            "type": "object",
            "properties": [
                "owner": [
                    "type": "string",
                    "description": "The repository owner — the user or organization. Get it from github_search_repositories' full_name (owner/repo). Never guess it, and never assume the signed-in user owns the repo: most repos that matter live under an organization.",
                ],
                "repo": [
                    "type": "string",
                    "description": "The repository name alone, without the owner.",
                ],
                "pull_number": [
                    "type": "integer",
                    "description": "The pull request number, as in #142. Get it from a list or a search.",
                ],
                "method": [
                    "type": "string",
                    "enum": [
                        "get",
                        "get_diff",
                        "get_status",
                        "get_files",
                        "get_reviews",
                        "get_review_comments",
                        "get_comments",
                    ],
                    "description": "Default get.",
                ],
                "per_page": [
                    "type": "integer",
                    "description": "How many results, 1 to 100. Default 20.",
                ],
                "page": [
                    "type": "integer",
                    "description": "Page number, for more results.",
                ],
            ],
            "required": ["owner", "repo", "pull_number"],
        ],
        "strict": false,
    ]

    static let githubSearchPullRequests: [String: Any] = [
        "type": "function",
        "name": "github_search_pull_requests",
        "description": "Find pull requests across repositories with GitHub search syntax — this is how \"my open PRs\" and \"what needs my review\" are answered. Useful qualifiers: `author:@me`, `review-requested:@me`, `is:open`, `draft:false`, `repo:owner/name`, `org:name`. `is:pr` is added for you.",
        "parameters": [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "GitHub search syntax.",
                ],
                "sort": [
                    "type": "string",
                    "enum": ["created", "updated", "comments"],
                    "description": "Default is best match.",
                ],
                "order": [
                    "type": "string",
                    "enum": ["asc", "desc"],
                ],
                "per_page": [
                    "type": "integer",
                    "description": "How many results, 1 to 100. Default 20.",
                ],
                "page": [
                    "type": "integer",
                    "description": "Page number, for more results.",
                ],
            ],
            "required": ["query"],
        ],
        "strict": false,
    ]

    static let githubListIssues: [String: Any] = [
        "type": "function",
        "name": "github_list_issues",
        "description": "Open issues in one repository. Pull requests are filtered out, so a count here is issues only. Narrow by label, assignee or creator when the user did.",
        "parameters": [
            "type": "object",
            "properties": [
                "owner": [
                    "type": "string",
                    "description": "The repository owner — the user or organization. Get it from github_search_repositories' full_name (owner/repo). Never guess it, and never assume the signed-in user owns the repo: most repos that matter live under an organization.",
                ],
                "repo": [
                    "type": "string",
                    "description": "The repository name alone, without the owner.",
                ],
                "state": [
                    "type": "string",
                    "enum": ["open", "closed", "all"],
                    "description": "Default open.",
                ],
                "labels": [
                    "type": "string",
                    "description": "Comma-separated label names.",
                ],
                "assignee": [
                    "type": "string",
                    "description": "A login, `none`, or `*` for any assignee.",
                ],
                "creator": [
                    "type": "string",
                    "description": "A login.",
                ],
                "since": [
                    "type": "string",
                    "description": "ISO-8601; only issues updated after it.",
                ],
                "sort": [
                    "type": "string",
                    "enum": ["created", "updated", "comments"],
                ],
                "direction": [
                    "type": "string",
                    "enum": ["asc", "desc"],
                ],
                "per_page": [
                    "type": "integer",
                    "description": "How many results, 1 to 100. Default 20.",
                ],
                "page": [
                    "type": "integer",
                    "description": "Page number, for more results.",
                ],
            ],
            "required": ["owner", "repo"],
        ],
        "strict": false,
    ]

    static let githubIssueRead: [String: Any] = [
        "type": "function",
        "name": "github_issue_read",
        "description": "One issue, by method: `get` for its body and state, `get_comments` for the discussion, `get_labels` for its labels, `get_sub_issues` for issues tracked underneath it.",
        "parameters": [
            "type": "object",
            "properties": [
                "owner": [
                    "type": "string",
                    "description": "The repository owner — the user or organization. Get it from github_search_repositories' full_name (owner/repo). Never guess it, and never assume the signed-in user owns the repo: most repos that matter live under an organization.",
                ],
                "repo": [
                    "type": "string",
                    "description": "The repository name alone, without the owner.",
                ],
                "issue_number": [
                    "type": "integer",
                    "description": "The issue number, as in #37. Get it from a list, a search, or a notification.",
                ],
                "method": [
                    "type": "string",
                    "enum": ["get", "get_comments", "get_labels", "get_sub_issues"],
                    "description": "Default get.",
                ],
                "per_page": [
                    "type": "integer",
                    "description": "How many results, 1 to 100. Default 20.",
                ],
            ],
            "required": ["owner", "repo", "issue_number"],
        ],
        "strict": false,
    ]

    static let githubSearchIssues: [String: Any] = [
        "type": "function",
        "name": "github_search_issues",
        "description": "Find issues across repositories with GitHub search syntax. Qualifiers that matter: `assignee:@me`, `author:@me`, `mentions:@me`, `is:open`, `label:bug`, `repo:owner/name`. `is:issue` is added for you, so pull requests will not come back.",
        "parameters": [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "GitHub search syntax.",
                ],
                "sort": [
                    "type": "string",
                    "enum": ["created", "updated", "comments"],
                ],
                "order": [
                    "type": "string",
                    "enum": ["asc", "desc"],
                ],
                "per_page": [
                    "type": "integer",
                    "description": "How many results, 1 to 100. Default 20.",
                ],
                "page": [
                    "type": "integer",
                    "description": "Page number, for more results.",
                ],
            ],
            "required": ["query"],
        ],
        "strict": false,
    ]

    static let githubListCommits: [String: Any] = [
        "type": "function",
        "name": "github_list_commits",
        "description": "Recent commits on a branch — who changed what, and when. Each comes back with a short sha, its subject line and the author. Narrow to one file with `path` when the user asked what happened to something specific.",
        "parameters": [
            "type": "object",
            "properties": [
                "owner": [
                    "type": "string",
                    "description": "The repository owner — the user or organization. Get it from github_search_repositories' full_name (owner/repo). Never guess it, and never assume the signed-in user owns the repo: most repos that matter live under an organization.",
                ],
                "repo": [
                    "type": "string",
                    "description": "The repository name alone, without the owner.",
                ],
                "sha": [
                    "type": "string",
                    "description": "Branch, tag or sha to start from.",
                ],
                "path": [
                    "type": "string",
                    "description": "Only commits touching this file or directory.",
                ],
                "author": [
                    "type": "string",
                    "description": "A login or email.",
                ],
                "since": [
                    "type": "string",
                    "description": "ISO-8601.",
                ],
                "until": [
                    "type": "string",
                    "description": "ISO-8601.",
                ],
                "per_page": [
                    "type": "integer",
                    "description": "How many results, 1 to 100. Default 20.",
                ],
                "page": [
                    "type": "integer",
                    "description": "Page number, for more results.",
                ],
            ],
            "required": ["owner", "repo"],
        ],
        "strict": false,
    ]

    static let githubGetCommit: [String: Any] = [
        "type": "function",
        "name": "github_get_commit",
        "description": "One commit in full — its whole message, the files it touched and how much of each. The diff itself is not included; there is nothing spoken to do with one.",
        "parameters": [
            "type": "object",
            "properties": [
                "owner": [
                    "type": "string",
                    "description": "The repository owner — the user or organization. Get it from github_search_repositories' full_name (owner/repo). Never guess it, and never assume the signed-in user owns the repo: most repos that matter live under an organization.",
                ],
                "repo": [
                    "type": "string",
                    "description": "The repository name alone, without the owner.",
                ],
                "sha": [
                    "type": "string",
                    "description": "A sha, branch or tag.",
                ],
            ],
            "required": ["owner", "repo", "sha"],
        ],
        "strict": false,
    ]

    static let githubGetFileContents: [String: Any] = [
        "type": "function",
        "name": "github_get_file_contents",
        "description": "Read a file from a repository, or list a directory — pass a file path for the first, a directory path or nothing for the second. Text only: a binary file is refused rather than read out as noise.",
        "parameters": [
            "type": "object",
            "properties": [
                "owner": [
                    "type": "string",
                    "description": "The repository owner — the user or organization. Get it from github_search_repositories' full_name (owner/repo). Never guess it, and never assume the signed-in user owns the repo: most repos that matter live under an organization.",
                ],
                "repo": [
                    "type": "string",
                    "description": "The repository name alone, without the owner.",
                ],
                "path": [
                    "type": "string",
                    "description": "Path in the repo. A directory, or empty, lists instead of reads.",
                ],
                "ref": [
                    "type": "string",
                    "description": "Branch, tag or sha. Default branch otherwise.",
                ],
            ],
            "required": ["owner", "repo"],
        ],
        "strict": false,
    ]

    static let githubSearchCode: [String: Any] = [
        "type": "function",
        "name": "github_search_code",
        "description": "Find where something is defined or mentioned in code, across repositories. Returns the file paths that match, which you then read with github_get_file_contents — the matching lines are not included, because a spoken answer is \"it's in three files\" and then the one that matters.",
        "parameters": [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "GitHub code search syntax. Narrow it: `repo:owner/name`, `path:lib/`, `language:swift`. An unqualified search across all of GitHub is rarely what the user meant.",
                ],
                "per_page": [
                    "type": "integer",
                    "description": "How many results, 1 to 100. Default 20.",
                ],
                "page": [
                    "type": "integer",
                    "description": "Page number, for more results.",
                ],
            ],
            "required": ["query"],
        ],
        "strict": false,
    ]

    static let githubActionsList: [String: Any] = [
        "type": "function",
        "name": "github_actions_list",
        "description": "CI, by method: `workflow_runs` (default) for recent runs and whether they passed — this is what \"did the build pass\" is answered from; `workflows` for the workflows a repo has, which is where a workflow_id for running one comes from; `workflow_jobs` for the jobs inside one run, which is how you find the job that failed.",
        "parameters": [
            "type": "object",
            "properties": [
                "owner": [
                    "type": "string",
                    "description": "The repository owner — the user or organization. Get it from github_search_repositories' full_name (owner/repo). Never guess it, and never assume the signed-in user owns the repo: most repos that matter live under an organization.",
                ],
                "repo": [
                    "type": "string",
                    "description": "The repository name alone, without the owner.",
                ],
                "method": [
                    "type": "string",
                    "enum": ["workflow_runs", "workflows", "workflow_jobs"],
                    "description": "Default workflow_runs.",
                ],
                "workflow_id": [
                    "type": "string",
                    "description": "For workflow_runs: narrow to one workflow, by file name (build.yml) or id.",
                ],
                "run_id": [
                    "type": "integer",
                    "description": "A workflow run's id, from github_actions_list method workflow_runs.",
                ],
                "branch": [
                    "type": "string",
                    "description": "Only runs on this branch.",
                ],
                "event": [
                    "type": "string",
                    "description": "push, pull_request, workflow_dispatch…",
                ],
                "status": [
                    "type": "string",
                    "description": "queued, in_progress, completed, success, failure, cancelled…",
                ],
                "actor": [
                    "type": "string",
                    "description": "Only runs started by this login.",
                ],
                "filter": [
                    "type": "string",
                    "enum": ["latest", "all"],
                    "description": "For workflow_jobs: `latest` attempt only, or all attempts.",
                ],
                "per_page": [
                    "type": "integer",
                    "description": "How many results, 1 to 100. Default 20.",
                ],
                "page": [
                    "type": "integer",
                    "description": "Page number, for more results.",
                ],
            ],
            "required": ["owner", "repo"],
        ],
        "strict": false,
    ]

    static let githubActionsGet: [String: Any] = [
        "type": "function",
        "name": "github_actions_get",
        "description": "One CI run or job, by method: `workflow_run` for a run's status and conclusion, `job` for one job including which of its steps failed, `workflow_run_usage` for how long a run took.",
        "parameters": [
            "type": "object",
            "properties": [
                "owner": [
                    "type": "string",
                    "description": "The repository owner — the user or organization. Get it from github_search_repositories' full_name (owner/repo). Never guess it, and never assume the signed-in user owns the repo: most repos that matter live under an organization.",
                ],
                "repo": [
                    "type": "string",
                    "description": "The repository name alone, without the owner.",
                ],
                "method": [
                    "type": "string",
                    "enum": ["workflow_run", "job", "workflow_run_usage"],
                    "description": "Default workflow_run.",
                ],
                "run_id": [
                    "type": "integer",
                    "description": "A workflow run's id, from github_actions_list method workflow_runs.",
                ],
                "job_id": [
                    "type": "integer",
                    "description": "A job's id, from github_actions_list workflow_jobs.",
                ],
            ],
            "required": ["owner", "repo"],
        ],
        "strict": false,
    ]

    static let githubGetJobLogs: [String: Any] = [
        "type": "function",
        "name": "github_get_job_logs",
        "description": "Why a build failed. Pass `failed_only` with a `run_id` when the user asked why CI broke and you do not know which job — it finds the failing jobs and tails each one, which is the fast path. Pass a `job_id` for one specific job. Only the end of each log comes back: a build log's beginning is the same setup steps every time and the answer is always at the end.",
        "parameters": [
            "type": "object",
            "properties": [
                "owner": [
                    "type": "string",
                    "description": "The repository owner — the user or organization. Get it from github_search_repositories' full_name (owner/repo). Never guess it, and never assume the signed-in user owns the repo: most repos that matter live under an organization.",
                ],
                "repo": [
                    "type": "string",
                    "description": "The repository name alone, without the owner.",
                ],
                "failed_only": [
                    "type": "boolean",
                    "description": "With run_id: tail the logs of every job that failed, up to three.",
                ],
                "run_id": [
                    "type": "integer",
                    "description": "A workflow run's id, from github_actions_list method workflow_runs.",
                ],
                "job_id": [
                    "type": "integer",
                    "description": "One job's id.",
                ],
                "tail_lines": [
                    "type": "integer",
                    "description": "How many lines from the end, 10 to 500. Default 120.",
                ],
            ],
            "required": ["owner", "repo"],
        ],
        "strict": false,
    ]

    static let githubListNotifications: [String: Any] = [
        "type": "function",
        "name": "github_list_notifications",
        "description": "The user's GitHub notifications — review requests, mentions, replies — each with the reason it arrived and the number of the pull request or issue it is about. This is what \"what needs my attention on GitHub\" is answered from, and it needs no repo.",
        "parameters": [
            "type": "object",
            "properties": [
                "all": [
                    "type": "boolean",
                    "description": "Include already-read ones. Default unread only.",
                ],
                "participating": [
                    "type": "boolean",
                    "description": "Only threads the user is directly involved in.",
                ],
                "since": [
                    "type": "string",
                    "description": "ISO-8601.",
                ],
                "before": [
                    "type": "string",
                    "description": "ISO-8601.",
                ],
                "per_page": [
                    "type": "integer",
                    "description": "How many results, 1 to 100. Default 20.",
                ],
                "page": [
                    "type": "integer",
                    "description": "Page number, for more results.",
                ],
            ],
        ],
        "strict": false,
    ]

    static let githubGetNotificationDetails: [String: Any] = [
        "type": "function",
        "name": "github_get_notification_details",
        "description": "One notification thread, when a list entry was not enough to say what it is about.",
        "parameters": [
            "type": "object",
            "properties": [
                "notification_id": [
                    "type": "string",
                    "description": "The `id` from github_list_notifications.",
                ],
            ],
            "required": ["notification_id"],
        ],
        "strict": false,
    ]

    static let githubListLabel: [String: Any] = [
        "type": "function",
        "name": "github_list_label",
        "description": "The labels a repository actually has, with their descriptions. Read these before labelling anything, and let the user pick from real names — a label that does not exist is silently dropped when an issue is filed.",
        "parameters": [
            "type": "object",
            "properties": [
                "owner": [
                    "type": "string",
                    "description": "The repository owner — the user or organization. Get it from github_search_repositories' full_name (owner/repo). Never guess it, and never assume the signed-in user owns the repo: most repos that matter live under an organization.",
                ],
                "repo": [
                    "type": "string",
                    "description": "The repository name alone, without the owner.",
                ],
                "per_page": [
                    "type": "integer",
                    "description": "How many results, 1 to 100. Default 20.",
                ],
            ],
            "required": ["owner", "repo"],
        ],
        "strict": false,
    ]

    static let githubMergePullRequest: [String: Any] = [
        "type": "function",
        "name": "github_merge_pull_request",
        "description": "Merge a pull request. This moves a branch other people are working on and sets off whatever is downstream of it — a deploy, a release — within seconds. Confirm across two turns first: name the pull request, its repo, its author and whether its checks pass, then merge in the next turn only on a clear yes. This tool only changes something on GitHub — it can never read, list, search or check anything. If you are answering a question, use the read tools instead.",
        "parameters": [
            "type": "object",
            "properties": [
                "owner": [
                    "type": "string",
                    "description": "The repository owner — the user or organization. Get it from github_search_repositories' full_name (owner/repo). Never guess it, and never assume the signed-in user owns the repo: most repos that matter live under an organization.",
                ],
                "repo": [
                    "type": "string",
                    "description": "The repository name alone, without the owner.",
                ],
                "pull_number": [
                    "type": "integer",
                    "description": "The pull request number, as in #142. Get it from a list or a search.",
                ],
                "merge_method": [
                    "type": "string",
                    "enum": ["merge", "squash", "rebase"],
                    "description": "Default is the repository's own default.",
                ],
                "commit_title": [
                    "type": "string",
                ],
                "commit_message": [
                    "type": "string",
                ],
            ],
            "required": ["owner", "repo", "pull_number"],
        ],
        "strict": false,
    ]

    static let githubIssueWrite: [String: Any] = [
        "type": "function",
        "name": "github_issue_write",
        "description": "File a new issue (`method: create`, needs a title) or change an existing one (`method: update`, needs an issue_number) — its title, body, labels, assignees, or open/closed state. Read the title and the repo back to the user before filing: a garbled title in the wrong repo is what this confirms against. Label only with names from github_list_label. This tool only changes something on GitHub — it can never read, list, search or check anything. If you are answering a question, use the read tools instead.",
        "parameters": [
            "type": "object",
            "properties": [
                "owner": [
                    "type": "string",
                    "description": "The repository owner — the user or organization. Get it from github_search_repositories' full_name (owner/repo). Never guess it, and never assume the signed-in user owns the repo: most repos that matter live under an organization.",
                ],
                "repo": [
                    "type": "string",
                    "description": "The repository name alone, without the owner.",
                ],
                "method": [
                    "type": "string",
                    "enum": ["create", "update"],
                    "description": "Default create.",
                ],
                "issue_number": [
                    "type": "integer",
                    "description": "The issue number, as in #37. Get it from a list, a search, or a notification.",
                ],
                "title": [
                    "type": "string",
                ],
                "body": [
                    "type": "string",
                ],
                "labels": [
                    "type": "array",
                    "items": [
                        "type": "string",
                    ],
                    "description": "Label names that exist in the repo — check with github_list_label.",
                ],
                "assignees": [
                    "type": "array",
                    "items": [
                        "type": "string",
                    ],
                    "description": "Logins.",
                ],
                "state": [
                    "type": "string",
                    "enum": ["open", "closed"],
                    "description": "For update.",
                ],
                "state_reason": [
                    "type": "string",
                    "enum": ["completed", "not_planned", "reopened"],
                    "description": "Why it closed.",
                ],
            ],
            "required": ["owner", "repo"],
        ],
        "strict": false,
    ]

    static let githubAddIssueComment: [String: Any] = [
        "type": "function",
        "name": "github_add_issue_comment",
        "description": "Comment on an issue or a pull request — pass its number either way. Everyone watching is emailed the moment it lands, and deleting the comment afterwards does not unsend that, so read the comment back before posting it. This tool only changes something on GitHub — it can never read, list, search or check anything. If you are answering a question, use the read tools instead.",
        "parameters": [
            "type": "object",
            "properties": [
                "owner": [
                    "type": "string",
                    "description": "The repository owner — the user or organization. Get it from github_search_repositories' full_name (owner/repo). Never guess it, and never assume the signed-in user owns the repo: most repos that matter live under an organization.",
                ],
                "repo": [
                    "type": "string",
                    "description": "The repository name alone, without the owner.",
                ],
                "issue_number": [
                    "type": "integer",
                    "description": "The issue or pull request number — pull requests take this too.",
                ],
                "body": [
                    "type": "string",
                    "description": "The comment.",
                ],
            ],
            "required": ["owner", "repo", "issue_number", "body"],
        ],
        "strict": false,
    ]

    static let githubUpdatePullRequest: [String: Any] = [
        "type": "function",
        "name": "github_update_pull_request",
        "description": "Change a pull request's own fields: `draft` true to put it back into draft or false to mark it ready for review, plus title, body, state (open/closed), reviewers and base branch. Routine — do it and say you did — with two exceptions. Marking a draft ready notifies its reviewers and putting it back does not unsend that, so say who was notified. And changing `base` decides where a later merge lands, so that one field is confirmed across two turns like a merge. This tool only changes something on GitHub — it can never read, list, search or check anything. If you are answering a question, use the read tools instead.",
        "parameters": [
            "type": "object",
            "properties": [
                "owner": [
                    "type": "string",
                    "description": "The repository owner — the user or organization. Get it from github_search_repositories' full_name (owner/repo). Never guess it, and never assume the signed-in user owns the repo: most repos that matter live under an organization.",
                ],
                "repo": [
                    "type": "string",
                    "description": "The repository name alone, without the owner.",
                ],
                "pull_number": [
                    "type": "integer",
                    "description": "The pull request number, as in #142. Get it from a list or a search.",
                ],
                "draft": [
                    "type": "boolean",
                    "description": "true puts it into draft, false marks it ready for review.",
                ],
                "title": [
                    "type": "string",
                ],
                "body": [
                    "type": "string",
                ],
                "state": [
                    "type": "string",
                    "enum": ["open", "closed"],
                ],
                "base": [
                    "type": "string",
                    "description": "The branch it would merge into. Confirm this one across two turns — it decides where a later merge lands.",
                ],
                "reviewers": [
                    "type": "array",
                    "items": [
                        "type": "string",
                    ],
                    "description": "Logins to ask.",
                ],
                "maintainer_can_modify": [
                    "type": "boolean",
                ],
            ],
            "required": ["owner", "repo", "pull_number"],
        ],
        "strict": false,
    ]

    static let githubActionsRunTrigger: [String: Any] = [
        "type": "function",
        "name": "github_actions_run_trigger",
        "description": "Start or stop CI: `run_workflow` dispatches a workflow against a branch (needs workflow_id and ref), `rerun_workflow_run` and `rerun_failed_jobs` run one again, `cancel_workflow_run` stops one in progress, `delete_workflow_run_logs` deletes a finished run's logs and cannot be undone. Confirm across two turns first, and read back the workflow, the repo AND the branch — a workflow run from the wrong branch can ship the wrong build. This tool only changes something on GitHub — it can never read, list, search or check anything. If you are answering a question, use the read tools instead.",
        "parameters": [
            "type": "object",
            "properties": [
                "owner": [
                    "type": "string",
                    "description": "The repository owner — the user or organization. Get it from github_search_repositories' full_name (owner/repo). Never guess it, and never assume the signed-in user owns the repo: most repos that matter live under an organization.",
                ],
                "repo": [
                    "type": "string",
                    "description": "The repository name alone, without the owner.",
                ],
                "method": [
                    "type": "string",
                    "enum": [
                        "run_workflow",
                        "rerun_workflow_run",
                        "rerun_failed_jobs",
                        "cancel_workflow_run",
                        "delete_workflow_run_logs",
                    ],
                ],
                "workflow_id": [
                    "type": "string",
                    "description": "For run_workflow: the workflow's file name (build.yml) or numeric id, from github_actions_list method workflows.",
                ],
                "ref": [
                    "type": "string",
                    "description": "For run_workflow: the branch or tag to run against. Read this back to the user — the wrong branch is the wrong build.",
                ],
                "inputs": [
                    "type": "object",
                    "description": "For run_workflow: the workflow's own dispatch inputs, if it takes any.",
                ],
                "run_id": [
                    "type": "integer",
                    "description": "A workflow run's id, from github_actions_list method workflow_runs.",
                ],
            ],
            "required": ["owner", "repo", "method"],
        ],
        "strict": false,
    ]
}
