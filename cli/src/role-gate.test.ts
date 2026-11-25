import { test, describe } from "node:test";
import { strict as assert } from "node:assert";
import { roleGate, type RoleGateDeps } from "./role-gate.js";
import type { SubagentCommandRequest } from "./subagents.js";
import type { Link } from "./types.js";

function deps(card: Partial<Link> | undefined, answer: { ok: boolean; error?: string } | Error) {
  const sent: SubagentCommandRequest[] = [];
  const d: RoleGateDeps = {
    currentCard: () => card as Link | undefined,
    branch: () => "feature",
    submit: async (request) => {
      sent.push(request);
      if (answer instanceof Error) throw answer;
      return { id: request.id, ok: answer.ok, error: answer.error };
    },
  };
  return { d, sent };
}

const input = (command: string) => JSON.stringify({ tool_name: "Bash", tool_input: { command }, cwd: "/repo" });

describe("kanban role gate", () => {
  test("asks Kanban Code for a role card and lets an allowed command run", async () => {
    const { d, sent } = deps({ id: "card_1", role: "build" }, { ok: true });
    assert.equal(await roleGate(input("git push"), d), undefined);
    assert.equal(sent.length, 1);
    assert.equal(sent[0].operation, "roleGate");
    assert.equal(sent[0].parentCardId, "card_1");
    assert.equal(sent[0].prompt, "git push");
    assert.equal(sent[0].branch, "feature");
  });

  test("turns a refusal into a PreToolUse deny with the reason", async () => {
    const { d } = deps({ id: "card_1", role: "build" }, { ok: false, error: "Refused: merging" });
    assert.deepEqual(await roleGate(input("gh pr merge 3"), d), {
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: "Refused: merging",
      },
    });
  });

  test("skips cards without a role, sessions outside a card and other tools", async () => {
    const noRole = deps({ id: "card_1" }, { ok: false });
    assert.equal(await roleGate(input("gh pr merge 3"), noRole.d), undefined);
    assert.equal(noRole.sent.length, 0);
    const noCard = deps(undefined, { ok: false });
    assert.equal(await roleGate(input("gh pr merge 3"), noCard.d), undefined);
    const edit = deps({ id: "card_1", role: "build" }, { ok: false });
    assert.equal(await roleGate(JSON.stringify({ tool_name: "Edit", tool_input: {} }), edit.d), undefined);
    assert.equal(await roleGate("not json", edit.d), undefined);
    assert.equal(edit.sent.length, 0);
  });

  test("refuses when Kanban Code does not answer", async () => {
    const { d } = deps({ id: "card_1", role: "build" }, new Error("timed out"));
    const answer = (await roleGate(input("pulumi up"), d)) as { hookSpecificOutput: { permissionDecision: string; permissionDecisionReason: string } };
    assert.equal(answer.hookSpecificOutput.permissionDecision, "deny");
    assert.match(answer.hookSpecificOutput.permissionDecisionReason, /did not answer/);
  });
});
