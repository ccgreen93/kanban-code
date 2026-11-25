import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("Role gate classifier")
struct RoleGateClassifierTests {
    private func actions(_ command: String, branch: String? = "feature", patterns: [String] = []) -> [GateAction] {
        RoleGateClassifier.classify(command, branch: branch, deployPatterns: patterns).map(\.action)
    }

    @Test func plainPushOfOwnBranch() {
        #expect(actions("git push") == [.push])
        #expect(actions("git push -u origin HEAD") == [.push])
        #expect(actions("git push origin feature") == [.push])
        #expect(actions("cd /repo && git -C /repo push 2>&1 | tail -5") == [.push])
    }

    @Test func pushToProtectedBranch() {
        #expect(actions("git push origin main") == [.protectedPush])
        #expect(actions("git push origin HEAD:main") == [.protectedPush])
        #expect(actions("git push origin feature:refs/heads/master") == [.protectedPush])
        #expect(actions("git push", branch: "main") == [.protectedPush])
        #expect(actions("git push origin release/1.2") == [.protectedPush])
        #expect(actions("git push --all") == [.protectedPush])
    }

    @Test func forcePushAndDeletes() {
        #expect(actions("git push --force").contains(.forcePush))
        #expect(actions("git push -f origin feature").contains(.forcePush))
        #expect(actions("git push -uf origin feature").contains(.forcePush))
        #expect(actions("git push --force-with-lease").contains(.forcePush))
        #expect(actions("git push origin +feature").contains(.forcePush))
        #expect(actions("git push origin :old-branch").contains(.forcePush))
        #expect(actions("git push origin --delete old").contains(.forcePush))
    }

    @Test func tagsAndDeployRemotesAreDeploys() {
        #expect(actions("git push --tags") == [.deploy])
        #expect(actions("git push origin v1.2.0").contains(.deploy))
        #expect(actions("git push heroku feature").contains(.deploy))
    }

    @Test func githubCLI() {
        #expect(actions("gh pr create --title 'feat: x' --body 'y'") == [.pr])
        #expect(actions("gh pr comment 12 --body done") == [.pr])
        #expect(actions("gh pr merge 12 --squash") == [.merge])
        #expect(actions("gh pr merge --auto --squash") == [.merge])
        #expect(actions("gh pr review 12 --approve") == [.approve])
        #expect(actions("gh pr checks --watch") == [])
        #expect(actions("gh pr view 12 --json state") == [])
        #expect(actions("gh release create v1.0") == [.deploy])
        #expect(actions("gh workflow run deploy.yml") == [.deploy])
        #expect(actions("GH_TOKEN=$(gh auth token) gh pr merge 3") == [.merge])
    }

    @Test func githubAPI() {
        #expect(actions("gh api -X PUT repos/o/r/pulls/3/merge") == [.merge])
        #expect(actions("gh api graphql -f query='mutation { enablePullRequestAutoMerge(input: {}) { clientMutationId } }'") == [.merge])
        #expect(actions("gh api repos/o/r/pulls/3/reviews -f event=APPROVE") == [.approve])
        #expect(actions("gh api repos/o/r/pulls/3/comments") == [])
        #expect(actions("curl -X PUT https://api.github.com/repos/o/r/pulls/3/merge") == [.merge])
    }

    @Test func deployTools() {
        for command in [
            "pulumi up --yes", "terraform apply -auto-approve", "kubectl apply -f k8s/",
            "helm upgrade app ./chart", "docker push ghcr.io/o/app:1", "docker buildx build --push .",
            "npm publish", "cargo publish", "flyctl deploy", "vercel --prod", "firebase deploy",
            "wrangler deploy", "make deploy", "npm run deploy:prod", "./scripts/deploy.sh",
            "ansible-playbook site.yml", "sudo -u app kubectl rollout restart deploy/web",
            "npx vercel deploy --prod", "kv env .env.vault -- pulumi up",
        ] {
            #expect(actions(command) == [.deploy], "\(command)")
        }
    }

    @Test func everydayCommandsPass() {
        for command in [
            "swift test", "npm test", "make build", "git status", "git commit -m 'gh pr merge later'",
            "pulumi preview", "terraform plan", "kubectl get pods", "docker compose up -d",
            "docker build -t app .", "git merge origin/main", "git rebase -i HEAD~2", "vercel",
            "ssh vx-pi 'docker compose logs --tail 50'", "scp vx-pi:/var/log/app.log .",
            "grep -rn deploy src", "echo 'git push origin main'",
        ] {
            #expect(actions(command).isEmpty, "\(command)")
        }
    }

    @Test func remoteCommandsOverSSH() {
        #expect(actions("ssh vx-pi 'cd /srv/vx && docker compose up -d'") == [.deploy])
        #expect(actions("ssh -p 22 vx-pi sudo systemctl restart vx") == [.deploy])
        #expect(actions("scp build.tar vx-pi:/srv/") == [.deploy])
        #expect(actions("bash -c 'gh pr merge 3'") == [.merge])
    }

    @Test func heredocBodiesAreData() {
        let handoff = """
        kanban role handoff review - <<'EOF'
        Pushed. Next: gh pr merge 12 once approved, then pulumi up.
        git push origin main
        EOF
        """
        #expect(actions(handoff).isEmpty)
        let commit = """
        git commit -F - <<EOF
        gh pr merge
        EOF
        git push
        """
        #expect(actions(commit) == [.push])
    }

    @Test func customDeployPatterns() {
        #expect(actions("./bin/ship-it now", patterns: ["^\\./bin/ship"]) == [.deploy])
        #expect(actions("ssh vx-pi uptime", patterns: ["^ssh vx-pi"]) == [.deploy])
    }

    @Test func everyMatchIsListed() {
        #expect(Set(actions("git push && gh pr create -f && gh pr merge --auto")) == [.push, .pr, .merge])
    }
}

@Suite("Role gate policy")
struct RoleGatePolicyTests {
    private func card(role: String? = "build", project: String = "/Users/me/dev/app") -> Link {
        var link = Link(
            id: "card_1", name: "Card", projectPath: project, column: .inProgress, source: .manual,
            tmuxLink: TmuxLink(sessionName: "app-card_1"),
            worktreeLink: WorktreeLink(path: project + "/.claude/worktrees/x", branch: "x")
        )
        link.role = role
        return link
    }

    @Test func defaultsAllowPushAndPRsButNotMergeOrDeploy() {
        let policy = RoleGatePolicy()
        #expect(RoleGate.decide(card: card(), command: "git push -u origin HEAD", branch: "x", policy: policy) == .allow)
        #expect(RoleGate.decide(card: card(), command: "gh pr create --fill", branch: "x", policy: policy) == .allow)
        for command in ["gh pr merge 3", "pulumi up", "git push origin main", "git push --force"] {
            guard case .deny(let reason) = RoleGate.decide(card: card(), command: command, branch: "x", policy: policy) else {
                Issue.record("\(command) was not refused"); continue
            }
            #expect(reason.contains("build role"))
        }
    }

    @Test func cardsWithoutARoleAreNotGated() {
        #expect(RoleGate.decide(card: card(role: nil), command: "gh pr merge 3", branch: nil, policy: RoleGatePolicy()) == .allow)
    }

    @Test func pushUsesTheWorktreeBranchWhenNoneIsGiven() {
        var main = card()
        main.worktreeLink = WorktreeLink(path: "/Users/me/dev/app", branch: "main")
        guard case .deny = RoleGate.decide(card: main, command: "git push", branch: nil, policy: RoleGatePolicy()) else {
            Issue.record("push from main was not refused"); return
        }
    }

    @Test func fileOverridesByRoleThenProject() throws {
        let json = """
        {
          "defaults": { "pr": "ask" },
          "deployPatterns": ["^ssh box"],
          "roles": { "review": { "merge": "ask" } },
          "projects": {
            "/Users/me/dev/app": { "merge": "allow", "deploy": "ask" },
            "/Users/me/dev": { "deploy": "allow" }
          }
        }
        """
        let policy = try #require(RoleGatePolicy.parse(Data(json.utf8)))
        #expect(policy.mode(for: .pr, role: "build", project: nil) == .ask)
        #expect(policy.mode(for: .merge, role: "review", project: nil) == .ask)
        #expect(policy.mode(for: .merge, role: "build", project: nil) == .deny)
        let app = policy.project(for: ["/Users/me/dev/app/.claude/worktrees/x"])
        #expect(policy.mode(for: .merge, role: "review", project: app) == .allow)
        #expect(policy.mode(for: .deploy, role: "build", project: app) == .ask)
        let other = policy.project(for: ["/Users/me/dev/other"])
        #expect(policy.mode(for: .deploy, role: "build", project: other) == .allow)
        #expect(policy.mode(for: .forcePush, role: "build", project: other) == .deny)
        #expect(policy.deployPatterns == ["^ssh box"])
    }

    @Test func tildeKeysExpand() throws {
        let policy = try #require(RoleGatePolicy.parse(Data(#"{"projects": {"~/dev/app": {"merge": "allow"}}}"#.utf8)))
        let home = NSHomeDirectory()
        #expect(policy.project(for: [home + "/dev/app"])?.modes[.merge] == .allow)
    }

    @Test func badFileFallsBackToBuiltIns() {
        #expect(RoleGatePolicy.parse(Data("not json".utf8)) == nil)
        let missing = RoleGatePolicy.load(path: "/nonexistent/gates.json")
        #expect(missing == RoleGatePolicy())
    }

    @Test func askHoldsThenApprovalAllowsOnce() {
        let policy = RoleGatePolicy(defaults: RoleGatePolicy.builtInDefaults.merging([.merge: .ask]) { $1 })
        var link = card()
        guard case .ask(let pending, let reason) = RoleGate.decide(card: link, command: "gh pr merge 3", branch: "x", policy: policy) else {
            Issue.record("merge was not held"); return
        }
        #expect(pending.action == .merge)
        #expect(pending.command == "gh pr merge 3")
        #expect(reason.contains("wait"))
        link.gateAllowances = ["gh pr merge 3"]
        #expect(RoleGate.decide(card: link, command: "gh pr merge 3", branch: "x", policy: policy) == .approved)
        guard case .ask = RoleGate.decide(card: link, command: "gh pr merge 4", branch: "x", policy: policy) else {
            Issue.record("a different command used the approval"); return
        }
    }

    @Test func strictestMatchWins() {
        let policy = RoleGatePolicy(defaults: RoleGatePolicy.builtInDefaults.merging([.pr: .ask]) { $1 })
        guard case .deny = RoleGate.decide(card: card(), command: "gh pr create && gh pr merge", branch: "x", policy: policy) else {
            Issue.record("deny did not win over ask"); return
        }
    }

    @Test func reducerHoldsApprovesAndConsumes() {
        var state = AppState()
        state.links["card_1"] = card()
        let pending = PendingGate(action: .merge, command: "gh pr merge 3", role: "build")
        _ = Reducer.reduce(state: &state, action: .setPendingGate(cardId: "card_1", gate: pending))
        #expect(state.links["card_1"]?.pendingGate == pending)
        _ = Reducer.reduce(state: &state, action: .resolvePendingGate(cardId: "card_1", approved: true))
        #expect(state.links["card_1"]?.pendingGate == nil)
        #expect(state.links["card_1"]?.gateAllowances == ["gh pr merge 3"])
        _ = Reducer.reduce(state: &state, action: .consumeGateAllowance(cardId: "card_1", command: "gh pr merge 3"))
        #expect(state.links["card_1"]?.gateAllowances == nil)

        _ = Reducer.reduce(state: &state, action: .setPendingGate(cardId: "card_1", gate: pending))
        _ = Reducer.reduce(state: &state, action: .resolvePendingGate(cardId: "card_1", approved: false))
        #expect(state.links["card_1"]?.pendingGate == nil)
        #expect(state.links["card_1"]?.gateAllowances == nil)
    }

    @Test func gateFieldsRoundTripAndClearOnHandoff() throws {
        var link = card()
        link.pendingGate = PendingGate(action: .deploy, command: "pulumi up", role: "build", requestedAt: Date(timeIntervalSince1970: 0))
        link.gateAllowances = ["gh pr merge 3"]
        let decoded = try JSONDecoder().decode(Link.self, from: JSONEncoder().encode(link))
        #expect(decoded.pendingGate == link.pendingGate)
        #expect(decoded.gateAllowances == ["gh pr merge 3"])
        let next = RoleHandoff.apply(to: link, next: Role(name: "review", body: "Review."), summary: "done")
        #expect(next.pendingGate == nil)
        #expect(next.gateAllowances == nil)
    }
}
