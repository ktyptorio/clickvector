import React, { useEffect, useMemo, useState } from "react";
import { createRoot } from "react-dom/client";
import { Archive, Download, FileText, LogOut, RefreshCw, Search, Upload } from "lucide-react";
import "./styles.css";

const API = import.meta.env.VITE_API_URL || "http://localhost:8000";

async function request(path, options = {}) {
  const res = await fetch(`${API}${path}`, {
    credentials: "include",
    ...options,
    headers: options.body instanceof FormData ? options.headers : { "Content-Type": "application/json", ...(options.headers || {}) },
  });
  if (!res.ok) {
    const data = await res.json().catch(() => ({}));
    throw new Error(data?.detail?.error?.message || data?.error?.message || `HTTP ${res.status}`);
  }
  if (res.status === 204) return null;
  return res.json();
}

function HealthBadge({ health }) {
  const label = health === "ok" ? "Backend healthy" : health === "checking" ? "Checking backend" : "Backend unavailable";
  return <span className={`health ${health}`}>{label}</span>;
}

function Auth({ onAuthed, health }) {
  const [mode, setMode] = useState("login");
  const [email, setEmail] = useState("user@example.com");
  const [password, setPassword] = useState("password123");
  const [displayName, setDisplayName] = useState("");
  const [error, setError] = useState("");

  async function submit(e) {
    e.preventDefault();
    setError("");
    try {
      const body = mode === "register" ? { email, password, display_name: displayName || null } : { email, password };
      const data = await request(`/api/auth/${mode}`, { method: "POST", body: JSON.stringify(body) });
      onAuthed(data.user);
    } catch (err) {
      setError(err.message);
    }
  }

  return (
    <main className="auth-page">
      <form className="auth-panel" onSubmit={submit}>
        <div className="auth-head"><div className="brand">ClickVector</div><HealthBadge health={health} /></div>
        <h1>{mode === "login" ? "Sign in" : "Create account"}</h1>
        <label>Email<input value={email} onChange={(e) => setEmail(e.target.value)} type="email" autoComplete="email" required /></label>
        <label>Password<input value={password} onChange={(e) => setPassword(e.target.value)} type="password" autoComplete={mode === "login" ? "current-password" : "new-password"} required /></label>
        {mode === "register" && <label>Display name<input value={displayName} onChange={(e) => setDisplayName(e.target.value)} autoComplete="name" /></label>}
        {error && <div className="error" role="alert">{error}</div>}
        <button className="primary" type="submit">{mode === "login" ? "Sign in" : "Register"}</button>
        <button type="button" className="link-button" onClick={() => setMode(mode === "login" ? "register" : "login")}>
          {mode === "login" ? "Create an account" : "Use existing account"}
        </button>
      </form>
    </main>
  );
}

function Documents({ search }) {
  const [docs, setDocs] = useState([]);
  const [readiness, setReadiness] = useState("all");
  const [limit, setLimit] = useState(25);
  const [offset, setOffset] = useState(0);
  const [page, setPage] = useState({ limit: 25, offset: 0, total: 0 });
  const [message, setMessage] = useState("");

  async function load(nextOffset = offset) {
    const params = new URLSearchParams({ readiness, limit: String(limit), offset: String(nextOffset) });
    if (search) params.set("q", search);
    const data = await request(`/api/documents?${params}`);
    setDocs(data.items);
    setPage(data.page);
    setOffset(data.page.offset);
  }

  useEffect(() => { setOffset(0); load(0).catch((e) => setMessage(e.message)); }, [readiness, limit, search]);

  async function upload(file) {
    if (!file) return;
    setMessage("Uploading...");
    const form = new FormData();
    form.append("file", file);
    await request("/api/documents", { method: "POST", body: form });
    setMessage("Uploaded. Ingestion is running.");
    await load(0);
  }

  async function replaceDoc(id, file) {
    if (!file) return;
    const form = new FormData();
    form.append("file", file);
    await request(`/api/documents/${id}/replace`, { method: "POST", body: form });
    await load(offset);
  }

  async function renameDoc(id, current) {
    const next = window.prompt("Rename document", current);
    if (!next) return;
    await request(`/api/documents/${id}`, { method: "PATCH", body: JSON.stringify({ display_name: next }) });
    await load(offset);
  }

  async function archiveDoc(id) {
    if (!window.confirm("Archive this document?")) return;
    await request(`/api/documents/${id}`, { method: "DELETE" });
    await load(offset);
  }

  const canPrev = page.offset > 0;
  const canNext = page.offset + page.limit < page.total;

  return (
    <section className="page-section" aria-labelledby="documents-title">
      <div className="toolbar">
        <label className="upload-button"><Upload size={16} aria-hidden="true" /> Upload<input aria-label="Upload PDF or DOCX" type="file" accept=".pdf,.docx" onChange={(e) => upload(e.target.files[0])} /></label>
        <label className="field-inline">Status
          <select value={readiness} onChange={(e) => setReadiness(e.target.value)}>
            <option value="all">All</option><option value="processing">Processing</option><option value="ready">Ready</option><option value="failed">Failed</option>
          </select>
        </label>
        <label className="field-inline">Rows
          <select value={limit} onChange={(e) => setLimit(Number(e.target.value))}>
            {[10, 25, 50].map((n) => <option key={n} value={n}>{n}</option>)}
          </select>
        </label>
        <button type="button" onClick={() => load(offset)}><RefreshCw size={16} aria-hidden="true" /> Refresh</button>
      </div>
      {message && <div className="notice" role="status">{message}</div>}
      <div className="table-wrap">
        <table className="documents-table">
          <thead>
            <tr><th scope="col">Name</th><th scope="col">Status</th><th scope="col">Chunks</th><th scope="col">Updated</th><th scope="col">Actions</th></tr>
          </thead>
          <tbody>
            {docs.map((d) => (
              <tr key={d.id}>
                <td><span className="doc-name"><FileText size={16} aria-hidden="true" /> {d.display_name}</span></td>
                <td><b className={`badge ${d.readiness}`}>{d.readiness}</b></td>
                <td>{d.chunk_count}</td>
                <td>{new Date(d.updated_at).toLocaleString()}</td>
                <td>
                  <span className="actions">
                    <button type="button" onClick={() => renameDoc(d.id, d.display_name)}>Rename</button>
                    <label className="mini-file">Replace<input aria-label={`Replace ${d.display_name}`} type="file" accept=".pdf,.docx" onChange={(e) => replaceDoc(d.id, e.target.files[0])} /></label>
                    <a aria-label={`Download ${d.display_name}`} href={`${API}${d.download_url}`}><Download size={15} aria-hidden="true" /></a>
                    <button type="button" aria-label={`Archive ${d.display_name}`} onClick={() => archiveDoc(d.id)}><Archive size={15} aria-hidden="true" /></button>
                  </span>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        {!docs.length && <div className="empty">No active documents.</div>}
      </div>
      <div className="pager" aria-label="Document pagination">
        <span>{page.total ? `${page.offset + 1}-${Math.min(page.offset + page.limit, page.total)} of ${page.total}` : "0 documents"}</span>
        <button type="button" disabled={!canPrev} onClick={() => load(Math.max(0, page.offset - page.limit))}>Previous</button>
        <button type="button" disabled={!canNext} onClick={() => load(page.offset + page.limit)}>Next</button>
      </div>
    </section>
  );
}

function QueryView() {
  const [query, setQuery] = useState("credential rotation and audit logging");
  const [topK, setTopK] = useState(10);
  const [results, setResults] = useState([]);
  const [loading, setLoading] = useState(false);

  async function submit(e) {
    e.preventDefault();
    setLoading(true);
    try {
      const data = await request("/api/query", { method: "POST", body: JSON.stringify({ query, top_k: Number(topK) }) });
      setResults(data.results);
    } finally {
      setLoading(false);
    }
  }

  return (
    <section className="page-section" aria-labelledby="query-title">
      <form className="query-panel" onSubmit={submit}>
        <label className="query-field">Query
          <textarea value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Ask across your ready documents" required />
        </label>
        <label className="topk-field">Results
          <select value={topK} onChange={(e) => setTopK(e.target.value)}>{[5, 10, 20, 50].map((n) => <option key={n} value={n}>Top {n}</option>)}</select>
        </label>
        <button className="primary" disabled={loading}>{loading ? "Searching..." : "Query"}</button>
      </form>
      <div className="results" aria-live="polite" aria-busy={loading}>
        {results.map((r) => (
          <article key={r.chunk_id} className="result">
            <div className="result-head"><b>{r.document_display_name}</b><span>Score {r.score.toFixed(3)} · Chunk {r.chunk_index}</span></div>
            <p>{r.chunk_text}</p>
            <a href={`${API}${r.download_url}`}>Download original</a>
          </article>
        ))}
        {!loading && !results.length && <div className="empty result-empty">No query results yet.</div>}
      </div>
    </section>
  );
}

function App() {
  const [user, setUser] = useState(null);
  const [view, setView] = useState("documents");
  const [health, setHealth] = useState("checking");
  const [documentSearch, setDocumentSearch] = useState("");
  const title = useMemo(() => view === "documents" ? "Documents" : "Query", [view]);

  useEffect(() => {
    request("/api/health").then(() => setHealth("ok")).catch(() => setHealth("down"));
  }, []);
  useEffect(() => { request("/api/auth/me").then((d) => setUser(d.user)).catch(() => {}); }, []);
  if (!user) return <Auth onAuthed={setUser} health={health} />;

  async function logout() {
    await request("/api/auth/logout", { method: "POST" });
    setUser(null);
  }

  return (
    <div className="shell">
      <aside className="sidebar">
        <div className="brand">ClickVector</div>
        <nav aria-label="Primary">
          <button className={view === "documents" ? "nav active" : "nav"} aria-current={view === "documents" ? "page" : undefined} onClick={() => setView("documents")}>Documents</button>
          <button className={view === "query" ? "nav active" : "nav"} aria-current={view === "query" ? "page" : undefined} onClick={() => setView("query")}>Query</button>
        </nav>
      </aside>
      <main className="app-main">
        <header className="topbar">
          <div className="topbar-title">
            <h1 id={view === "documents" ? "documents-title" : "query-title"}>{title}</h1>
            <span>{view === "documents" ? "Manage uploaded PDF and DOCX files" : "Search ready document chunks"}</span>
          </div>
          {view === "documents" ? (
            <label className="topbar-search"><Search size={16} aria-hidden="true" /><span className="sr-only">Search documents</span><input placeholder="Search documents" value={documentSearch} onChange={(e) => setDocumentSearch(e.target.value)} /></label>
          ) : (
            <div className="topbar-context"><Search size={16} aria-hidden="true" /><span>Ready documents only</span></div>
          )}
          <div className="user-menu" aria-label="User menu">
            <HealthBadge health={health} />
            <span className="user-email">{user.email}</span>
            <button type="button" onClick={logout}><LogOut size={15} aria-hidden="true" /> Logout</button>
          </div>
        </header>
        {view === "documents" ? <Documents search={documentSearch} /> : <QueryView />}
      </main>
    </div>
  );
}

createRoot(document.getElementById("root")).render(<App />);
