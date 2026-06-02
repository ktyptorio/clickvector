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

function Auth({ onAuthed }) {
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
        <div className="brand">ClickVector</div>
        <h1>{mode === "login" ? "Sign in" : "Create account"}</h1>
        <label>Email<input value={email} onChange={(e) => setEmail(e.target.value)} type="email" /></label>
        <label>Password<input value={password} onChange={(e) => setPassword(e.target.value)} type="password" /></label>
        {mode === "register" && <label>Display name<input value={displayName} onChange={(e) => setDisplayName(e.target.value)} /></label>}
        {error && <div className="error">{error}</div>}
        <button className="primary" type="submit">{mode === "login" ? "Sign in" : "Register"}</button>
        <button type="button" className="link-button" onClick={() => setMode(mode === "login" ? "register" : "login")}>
          {mode === "login" ? "Create an account" : "Use existing account"}
        </button>
      </form>
    </main>
  );
}

function Documents() {
  const [docs, setDocs] = useState([]);
  const [q, setQ] = useState("");
  const [readiness, setReadiness] = useState("all");
  const [message, setMessage] = useState("");

  async function load() {
    const params = new URLSearchParams({ readiness, limit: "50", offset: "0" });
    if (q) params.set("q", q);
    const data = await request(`/api/documents?${params}`);
    setDocs(data.items);
  }

  useEffect(() => { load().catch((e) => setMessage(e.message)); }, [readiness]);

  async function upload(file) {
    if (!file) return;
    setMessage("Uploading...");
    const form = new FormData();
    form.append("file", file);
    await request("/api/documents", { method: "POST", body: form });
    setMessage("Uploaded. Ingestion is running.");
    await load();
  }

  async function replaceDoc(id, file) {
    if (!file) return;
    const form = new FormData();
    form.append("file", file);
    await request(`/api/documents/${id}/replace`, { method: "POST", body: form });
    await load();
  }

  async function renameDoc(id, current) {
    const next = window.prompt("Rename document", current);
    if (!next) return;
    await request(`/api/documents/${id}`, { method: "PATCH", body: JSON.stringify({ display_name: next }) });
    await load();
  }

  async function archiveDoc(id) {
    if (!window.confirm("Archive this document?")) return;
    await request(`/api/documents/${id}`, { method: "DELETE" });
    await load();
  }

  return (
    <section>
      <div className="toolbar">
        <label className="upload-button"><Upload size={16} /> Upload<input type="file" accept=".pdf,.docx" onChange={(e) => upload(e.target.files[0])} /></label>
        <div className="searchbox"><Search size={16} /><input placeholder="Search documents" value={q} onChange={(e) => setQ(e.target.value)} onKeyDown={(e) => e.key === "Enter" && load()} /></div>
        <select value={readiness} onChange={(e) => setReadiness(e.target.value)}>
          <option value="all">All</option><option value="processing">Processing</option><option value="ready">Ready</option><option value="failed">Failed</option>
        </select>
        <button onClick={load}><RefreshCw size={16} /></button>
      </div>
      {message && <div className="notice">{message}</div>}
      <div className="table">
        <div className="row header"><span>Name</span><span>Status</span><span>Chunks</span><span>Updated</span><span>Actions</span></div>
        {docs.map((d) => (
          <div className="row" key={d.id}>
            <span className="doc-name"><FileText size={16} /> {d.display_name}</span>
            <span><b className={`badge ${d.readiness}`}>{d.readiness}</b></span>
            <span>{d.chunk_count}</span>
            <span>{new Date(d.updated_at).toLocaleString()}</span>
            <span className="actions">
              <button onClick={() => renameDoc(d.id, d.display_name)}>Rename</button>
              <label className="mini-file">Replace<input type="file" accept=".pdf,.docx" onChange={(e) => replaceDoc(d.id, e.target.files[0])} /></label>
              <a href={`${API}${d.download_url}`}><Download size={15} /></a>
              <button onClick={() => archiveDoc(d.id)}><Archive size={15} /></button>
            </span>
          </div>
        ))}
        {!docs.length && <div className="empty">No active documents.</div>}
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
    <section>
      <form className="query-panel" onSubmit={submit}>
        <textarea value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Ask across your ready documents" />
        <select value={topK} onChange={(e) => setTopK(e.target.value)}>{[5, 10, 20, 50].map((n) => <option key={n} value={n}>Top {n}</option>)}</select>
        <button className="primary" disabled={loading}>{loading ? "Searching..." : "Query"}</button>
      </form>
      <div className="results">
        {results.map((r) => (
          <article key={r.chunk_id} className="result">
            <div><b>{r.document_display_name}</b><span>Score {r.score.toFixed(3)} · Chunk {r.chunk_index}</span></div>
            <p>{r.chunk_text}</p>
            <a href={`${API}${r.download_url}`}>Download original</a>
          </article>
        ))}
      </div>
    </section>
  );
}

function App() {
  const [user, setUser] = useState(null);
  const [view, setView] = useState("documents");
  const title = useMemo(() => view === "documents" ? "Documents" : "Query", [view]);

  useEffect(() => { request("/api/auth/me").then((d) => setUser(d.user)).catch(() => {}); }, []);
  if (!user) return <Auth onAuthed={setUser} />;

  async function logout() {
    await request("/api/auth/logout", { method: "POST" });
    setUser(null);
  }

  return (
    <div className="shell">
      <aside>
        <div className="brand">ClickVector</div>
        <button className={view === "documents" ? "nav active" : "nav"} onClick={() => setView("documents")}>Documents</button>
        <button className={view === "query" ? "nav active" : "nav"} onClick={() => setView("query")}>Query</button>
      </aside>
      <main>
        <header><h1>{title}</h1><div>{user.email} <button onClick={logout}><LogOut size={15} /> Logout</button></div></header>
        {view === "documents" ? <Documents /> : <QueryView />}
      </main>
    </div>
  );
}

createRoot(document.getElementById("root")).render(<App />);
