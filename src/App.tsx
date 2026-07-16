import { useCallback, useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { ArrowUp, Check, Copy, Plus, RefreshCw, Users, X } from "lucide-react";
import "./index.css";
import { Button } from "@/components/ui/button";

type Member = { account: string | null; device: string };

type ChatEventPayload =
  | { type: "conversationStarted"; convoId: string; class: string }
  | { type: "messageReceived"; convoId: string; content: string; sender: Member }
  | { type: "inboundError"; message: string };

type ChatStatus = { state: "starting" | "ready" | "failed"; address: string | null; error: string | null };

type Message = {
  id: number;
  content: string;
  sender: string | null;
  self: boolean;
  at: number;
};

type Group = {
  id: string;
  messages: Message[];
  members: Member[];
};

type Engine =
  | { state: "starting" }
  | { state: "ready"; address: string }
  | { state: "failed"; error: string };

function short(id: string, n = 8) {
  return id.length > n ? `${id.slice(0, n)}…` : id;
}

function parseAddresses(raw: string): string[] {
  return raw
    .split(/[\s,;]+/)
    .map((s) => s.trim())
    .filter(Boolean);
}

let nextMessageId = 1;

function App() {
  const [engine, setEngine] = useState<Engine>({ state: "starting" });
  const [groups, setGroups] = useState<Record<string, Group>>({});
  const [order, setOrder] = useState<string[]>([]);
  const [activeId, setActiveId] = useState<string | null>(null);
  const [banner, setBanner] = useState<string | null>(null);

  const [showNewGroup, setShowNewGroup] = useState(false);
  const [showAddMembers, setShowAddMembers] = useState(false);
  const [draft, setDraft] = useState("");
  const [addressesDraft, setAddressesDraft] = useState("");
  const [busy, setBusy] = useState(false);
  const [copied, setCopied] = useState(false);

  const scrollRef = useRef<HTMLDivElement>(null);
  const myAddressRef = useRef<string | null>(null);
  myAddressRef.current = engine.state === "ready" ? engine.address : null;

  const upsertGroup = useCallback((id: string, update?: (g: Group) => Group) => {
    setGroups((prev) => {
      const existing = prev[id] ?? { id, messages: [], members: [] };
      return { ...prev, [id]: update ? update(existing) : existing };
    });
    setOrder((prev) => (prev.includes(id) ? prev : [...prev, id]));
  }, []);

  const refreshMembers = useCallback(
    async (convoId: string) => {
      try {
        const members = await invoke<Member[]>("group_members", { convoId });
        upsertGroup(convoId, (g) => ({ ...g, members }));
      } catch {
        // roster lookups can fail transiently (directory offline); keep the old list
      }
    },
    [upsertGroup],
  );

  const loadGroups = useCallback(async () => {
    try {
      const ids = await invoke<string[]>("list_groups");
      for (const id of ids) {
        upsertGroup(id);
        void refreshMembers(id);
      }
    } catch {
      // engine not ready yet; conversations arrive via events instead
    }
  }, [upsertGroup, refreshMembers]);

  useEffect(() => {
    const unlisteners: Array<() => void> = [];
    let cancelled = false;
    // In development, StrictMode unmounts and remounts this effect before the
    // async listen() calls resolve; registering through `add` guarantees a
    // listener set up after cleanup is torn down immediately instead of
    // leaking (a leaked listener shows every message twice).
    const add = (unlisten: () => void) => {
      if (cancelled) unlisten();
      else unlisteners.push(unlisten);
    };

    (async () => {
      add(
        await listen<string>("chat-ready", (e) => {
          setEngine({ state: "ready", address: e.payload });
          void loadGroups();
        }),
      );
      add(
        await listen<string>("chat-error", (e) => {
          setEngine({ state: "failed", error: e.payload });
        }),
      );
      add(
        await listen<ChatEventPayload>("chat-event", (e) => {
          const ev = e.payload;
          if (ev.type === "conversationStarted") {
            upsertGroup(ev.convoId);
            void refreshMembers(ev.convoId);
          } else if (ev.type === "messageReceived") {
            // Our own messages are rendered when sent; drop any echo of them
            // (e.g. history replayed by the transport after a restart).
            if (ev.sender.account && ev.sender.account === myAddressRef.current) return;
            upsertGroup(ev.convoId, (g) => ({
              ...g,
              messages: [
                ...g.messages,
                {
                  id: nextMessageId++,
                  content: ev.content,
                  sender: ev.sender.account ?? ev.sender.device,
                  self: false,
                  at: Date.now(),
                },
              ],
            }));
          } else if (ev.type === "inboundError") {
            setBanner(ev.message);
          }
        }),
      );

      // Catch up in case the engine settled before our listeners attached.
      const status = await invoke<ChatStatus>("chat_status");
      if (cancelled) return;
      if (status.state === "ready" && status.address) {
        setEngine({ state: "ready", address: status.address });
        void loadGroups();
      } else if (status.state === "failed") {
        setEngine({ state: "failed", error: status.error ?? "unknown error" });
      }
    })();

    return () => {
      cancelled = true;
      unlisteners.forEach((fn) => fn());
    };
  }, [loadGroups, refreshMembers, upsertGroup]);

  // Keep the active group's roster fresh: adds commit asynchronously.
  useEffect(() => {
    if (!activeId) return;
    void refreshMembers(activeId);
    const timer = setInterval(() => void refreshMembers(activeId), 30_000);
    return () => clearInterval(timer);
  }, [activeId, refreshMembers]);

  useEffect(() => {
    const el = scrollRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [activeId, groups]);

  const active = activeId ? groups[activeId] : null;
  const myAddress = engine.state === "ready" ? engine.address : null;

  async function createGroup() {
    setBusy(true);
    setBanner(null);
    try {
      const members = parseAddresses(addressesDraft);
      const id = await invoke<string>("create_group", { members });
      upsertGroup(id);
      setActiveId(id);
      setShowNewGroup(false);
      setAddressesDraft("");
      void refreshMembers(id);
    } catch (e) {
      setBanner(String(e));
    } finally {
      setBusy(false);
    }
  }

  async function addMembers() {
    if (!activeId) return;
    setBusy(true);
    setBanner(null);
    try {
      const members = parseAddresses(addressesDraft);
      if (members.length > 0) {
        await invoke("add_members", { convoId: activeId, members });
      }
      setShowAddMembers(false);
      setAddressesDraft("");
    } catch (e) {
      setBanner(String(e));
    } finally {
      setBusy(false);
    }
  }

  async function sendMessage() {
    const content = draft.trim();
    if (!content || !activeId) return;
    setBanner(null);
    try {
      await invoke("send_group_message", { convoId: activeId, content });
      upsertGroup(activeId, (g) => ({
        ...g,
        messages: [
          ...g.messages,
          { id: nextMessageId++, content, sender: null, self: true, at: Date.now() },
        ],
      }));
      setDraft("");
    } catch (e) {
      setBanner(String(e));
    }
  }

  async function copyAddress() {
    if (!myAddress) return;
    await navigator.clipboard.writeText(myAddress);
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
  }

  function memberLabel(m: Member) {
    const id = m.account ?? m.device;
    return id === myAddress ? `${short(id)} (you)` : short(id, 12);
  }

  return (
    <div className="flex h-svh bg-background text-foreground">
      {/* Sidebar */}
      <aside className="flex w-64 shrink-0 flex-col border-r bg-sidebar text-sidebar-foreground">
        <div className="flex items-center justify-between px-4 pt-4 pb-2">
          <h1 className="text-base font-semibold">Ferry</h1>
          <Button
            size="icon-sm"
            variant="ghost"
            aria-label="New group"
            disabled={engine.state !== "ready"}
            onClick={() => {
              setAddressesDraft("");
              setShowNewGroup(true);
            }}
          >
            <Plus />
          </Button>
        </div>

        <div className="flex-1 overflow-y-auto px-2">
          {order.length === 0 && (
            <p className="px-2 py-3 text-sm text-muted-foreground">
              No groups yet. Create one and share your address with friends.
            </p>
          )}
          {order.map((id) => {
            const g = groups[id];
            const last = g.messages[g.messages.length - 1];
            return (
              <button
                key={id}
                onClick={() => setActiveId(id)}
                className={`mb-1 w-full rounded-lg px-3 py-2 text-left transition-colors ${
                  id === activeId ? "bg-sidebar-accent text-sidebar-accent-foreground" : "hover:bg-sidebar-accent/60"
                }`}
              >
                <div className="flex items-center justify-between gap-2">
                  <span className="truncate text-sm font-medium">Group {short(id)}</span>
                  <span className="flex items-center gap-1 text-xs text-muted-foreground">
                    <Users className="size-3" />
                    {g.members.length || "…"}
                  </span>
                </div>
                <p className="truncate text-xs text-muted-foreground">
                  {last ? last.content : "no messages yet"}
                </p>
              </button>
            );
          })}
        </div>

        <div className="border-t p-3">
          {engine.state === "starting" && (
            <p className="text-xs text-muted-foreground">Starting chat engine, connecting to the network…</p>
          )}
          {engine.state === "failed" && (
            <p className="text-xs text-destructive">Engine failed: {engine.error}</p>
          )}
          {engine.state === "ready" && (
            <div className="flex items-center gap-2">
              <span className="size-2 shrink-0 rounded-full bg-primary" />
              <div className="min-w-0 flex-1">
                <p className="text-xs text-muted-foreground">Your address</p>
                <p className="truncate font-mono text-xs">{engine.address}</p>
              </div>
              <Button size="icon-xs" variant="ghost" aria-label="Copy address" onClick={copyAddress}>
                {copied ? <Check /> : <Copy />}
              </Button>
            </div>
          )}
        </div>
      </aside>

      {/* Main pane */}
      <main className="flex min-w-0 flex-1 flex-col">
        {banner && (
          <div className="flex items-center justify-between gap-2 border-b bg-destructive/10 px-4 py-2 text-sm text-destructive">
            <span className="truncate">{banner}</span>
            <Button size="icon-xs" variant="ghost" aria-label="Dismiss" onClick={() => setBanner(null)}>
              <X />
            </Button>
          </div>
        )}

        {!active ? (
          <div className="flex flex-1 flex-col items-center justify-center gap-3 p-8 text-center">
            <Users className="size-10 text-muted-foreground" />
            <h2 className="text-lg font-medium">End-to-end encrypted group chat</h2>
            <p className="max-w-md text-sm text-muted-foreground">
              Create a group with your friends' account addresses, or wait for an invite to arrive. Group
              invites are committed asynchronously and can take a minute to land.
            </p>
            <Button disabled={engine.state !== "ready"} onClick={() => setShowNewGroup(true)}>
              <Plus data-icon="inline-start" />
              New group
            </Button>
          </div>
        ) : (
          <>
            <header className="flex items-center gap-2 border-b px-4 py-3">
              <div className="min-w-0 flex-1">
                <h2 className="truncate text-sm font-semibold">Group {short(active.id)}</h2>
                <p className="truncate text-xs text-muted-foreground">
                  {active.members.length > 0
                    ? active.members.map(memberLabel).join(", ")
                    : "membership pending"}
                </p>
              </div>
              <Button
                size="icon-sm"
                variant="ghost"
                aria-label="Refresh members"
                onClick={() => activeId && refreshMembers(activeId)}
              >
                <RefreshCw />
              </Button>
              <Button
                size="sm"
                variant="outline"
                onClick={() => {
                  setAddressesDraft("");
                  setShowAddMembers(true);
                }}
              >
                <Plus data-icon="inline-start" />
                Add members
              </Button>
            </header>

            <div ref={scrollRef} className="flex-1 space-y-3 overflow-y-auto px-4 py-4">
              {active.messages.length === 0 && (
                <p className="pt-8 text-center text-sm text-muted-foreground">
                  No messages yet. Say hello — newly invited members receive messages once their welcome
                  lands.
                </p>
              )}
              {active.messages.map((m) => (
                <div key={m.id} className={`flex ${m.self ? "justify-end" : "justify-start"}`}>
                  <div
                    className={`max-w-[70%] rounded-2xl px-3 py-2 ${
                      m.self ? "bg-primary text-primary-foreground" : "bg-muted"
                    }`}
                  >
                    {!m.self && m.sender && (
                      <p className="mb-0.5 font-mono text-[10px] opacity-70">{short(m.sender, 12)}</p>
                    )}
                    <p className="text-sm break-words whitespace-pre-wrap">{m.content}</p>
                  </div>
                </div>
              ))}
            </div>

            <form
              className="flex items-center gap-2 border-t px-4 py-3"
              onSubmit={(e) => {
                e.preventDefault();
                void sendMessage();
              }}
            >
              <input
                value={draft}
                onChange={(e) => setDraft(e.target.value)}
                placeholder="Message the group…"
                className="h-9 flex-1 rounded-4xl border bg-input/30 px-4 text-sm outline-none focus-visible:border-ring focus-visible:ring-[3px] focus-visible:ring-ring/50"
              />
              <Button type="submit" size="icon" aria-label="Send" disabled={!draft.trim()}>
                <ArrowUp />
              </Button>
            </form>
          </>
        )}
      </main>

      {/* New group / add members dialog */}
      {(showNewGroup || showAddMembers) && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
          <div className="w-full max-w-md rounded-2xl border bg-card p-5 text-card-foreground shadow-lg">
            <div className="mb-3 flex items-center justify-between">
              <h3 className="text-base font-semibold">
                {showNewGroup ? "New group" : `Add members to group ${activeId ? short(activeId) : ""}`}
              </h3>
              <Button
                size="icon-xs"
                variant="ghost"
                aria-label="Close"
                onClick={() => {
                  setShowNewGroup(false);
                  setShowAddMembers(false);
                }}
              >
                <X />
              </Button>
            </div>
            <p className="mb-2 text-sm text-muted-foreground">
              Paste account addresses (one per line or comma separated).
              {showNewGroup && " Leave empty to start a group with just yourself."}
            </p>
            <textarea
              value={addressesDraft}
              onChange={(e) => setAddressesDraft(e.target.value)}
              rows={4}
              autoFocus
              placeholder="e.g. 3fa1bc90…"
              className="mb-2 w-full resize-none rounded-lg border bg-input/30 p-3 font-mono text-xs outline-none focus-visible:border-ring focus-visible:ring-[3px] focus-visible:ring-ring/50"
            />
            <p className="mb-4 text-xs text-muted-foreground">
              Invites are staged as proposals and committed asynchronously — members can take around a
              minute to appear.
            </p>
            <div className="flex justify-end gap-2">
              <Button
                variant="ghost"
                onClick={() => {
                  setShowNewGroup(false);
                  setShowAddMembers(false);
                }}
              >
                Cancel
              </Button>
              <Button disabled={busy} onClick={() => (showNewGroup ? createGroup() : addMembers())}>
                {busy ? "Working…" : showNewGroup ? "Create group" : "Add members"}
              </Button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

export default App;
