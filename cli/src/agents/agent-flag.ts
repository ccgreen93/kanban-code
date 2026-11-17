import { setCardAgentOnDisk } from "../cards.js";
import {
  kanbanCodeIsRunning,
  makeSubagentRequest,
  submitSubagentRequest,
  type SubagentCommandRequest,
  type SubagentCommandResponse,
} from "../subagents.js";

/// The card to move. `sessionId` and `tmuxName` let a running app find a
/// card the CLI just launched: a card written to links.json underneath it is
/// replaced by the one the app discovers for the same session.
export interface AgentFlagTarget {
  cardId: string;
  sessionId?: string;
  tmuxName?: string;
}

export interface AgentFlagDeps {
  appRunning(): boolean;
  submit(request: SubagentCommandRequest): Promise<SubagentCommandResponse>;
  writeDisk(cardId: string, isAgent: boolean): boolean;
}

const REAL_DEPS: AgentFlagDeps = {
  appRunning: kanbanCodeIsRunning,
  submit: (request) => submitSubagentRequest(request),
  writeDisk: (cardId, isAgent) => !!setCardAgentOnDisk(cardId, isAgent),
};

/// Move a card into the Agents section (isAgent) or back onto the board.
/// A running Kanban Code owns links.json, so the change goes through its
/// command mailbox; without the app it is written to links.json directly.
/// Returns the id of the card that was changed, which under a running app
/// may be the app's card for the session rather than `target.cardId`.
export async function setCardAgent(
  target: AgentFlagTarget,
  isAgent: boolean,
  deps: AgentFlagDeps = REAL_DEPS
): Promise<string> {
  if (deps.appRunning()) {
    const response = await deps.submit(
      makeSubagentRequest("setAgent", target.cardId, {
        cardId: target.cardId,
        sessionId: target.sessionId,
        name: target.tmuxName,
        isAgent,
      })
    );
    if (!response.ok) throw new Error(response.error ?? "unknown error");
    return response.cardId ?? target.cardId;
  }
  if (!deps.writeDisk(target.cardId, isAgent)) {
    throw new Error(`Card not found: ${target.cardId}`);
  }
  return target.cardId;
}
