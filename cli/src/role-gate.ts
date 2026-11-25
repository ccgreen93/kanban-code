import { execFileSync } from "node:child_process";
import { currentCardOrThrow, makeSubagentRequest, submitSubagentRequest } from "./subagents.js";
import type { SubagentCommandRequest, SubagentCommandResponse } from "./subagents.js";
import { readLinks } from "./data.js";
import type { Link } from "./types.js";

/** What Claude Code and Codex send a PreToolUse hook. */
export interface GateHookInput {
  tool_name?: string;
  tool_input?: { command?: string };
  cwd?: string;
}

export interface RoleGateDeps {
  currentCard: () => Link | undefined;
  branch: (cwd: string | undefined) => string | undefined;
  submit: (request: SubagentCommandRequest) => Promise<SubagentCommandResponse>;
}

const defaultDeps: RoleGateDeps = {
  currentCard: () => {
    try {
      return currentCardOrThrow(readLinks());
    } catch {
      return undefined;
    }
  },
  branch: (cwd) => {
    try {
      const out = execFileSync("git", ["rev-parse", "--abbrev-ref", "HEAD"], {
        cwd: cwd || process.cwd(),
        encoding: "utf-8",
        stdio: ["ignore", "pipe", "ignore"],
        timeout: 3_000,
      }).trim();
      return out && out !== "HEAD" ? out : undefined;
    } catch {
      return undefined;
    }
  },
  submit: (request) => submitSubagentRequest(request, { timeoutMs: 15_000 }),
};

function deny(reason: string): unknown {
  return {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: reason,
    },
  };
}

/**
 * `kanban role gate`, the PreToolUse hook of a role card: asks Kanban Code
 * whether the agent may run its Bash command. Returns the hook's answer, or
 * undefined to let the command run (not a card, no role, or allowed).
 */
export async function roleGate(raw: string, deps: RoleGateDeps = defaultDeps): Promise<unknown> {
  let input: GateHookInput;
  try {
    input = JSON.parse(raw) as GateHookInput;
  } catch {
    return undefined;
  }
  if (input.tool_name !== "Bash") return undefined;
  const command = input.tool_input?.command;
  if (!command?.trim()) return undefined;
  const card = deps.currentCard();
  if (!card?.role) return undefined;
  let response: SubagentCommandResponse;
  try {
    response = await deps.submit(
      makeSubagentRequest("roleGate", card.id, { prompt: command, branch: deps.branch(input.cwd) })
    );
  } catch (error) {
    return deny(
      `Kanban Code did not answer the role gate, so this command was not run (${
        error instanceof Error ? error.message : String(error)
      }). Try once more in a minute; if it fails again, report and stop.`
    );
  }
  if (response.ok) return undefined;
  return deny(response.error ?? "Refused by the Kanban Code role gate.");
}
