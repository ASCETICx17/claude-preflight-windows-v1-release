"use strict";
// No microphone/camera access, remote scripts, account data or persistent storage.
async function runGuardWebRTCProbe(options = {}) {
  const servers = options.servers || [
    "stun:stun.cloudflare.com:3478",
    "stun:stun.l.google.com:19302"
  ];
  const timeoutMs = options.timeoutMs || 30000;
  const retryTimeoutMs = options.retryTimeoutMs || 2500;
  const deadline = Math.min(Date.now() + Math.min(30000, options.totalTimeoutMs || 30000),
    Number.isFinite(options.deadlineEpochMs) ? options.deadlineEpochMs : Infinity);
  const remaining = () => Math.max(0, deadline - Date.now());
  if (typeof RTCPeerConnection !== "function") {
    return { supported: false, probes: [] };
  }
  const probeOnce = (definition, budget) => new Promise(resolve => {
    const server = typeof definition === "string" ? definition : definition.id;
    const urls = typeof definition === "string" ? definition : definition.urls;
    const resolution = typeof definition === "string" ? "system_dns" : definition.resolution;
    let peer, timer, finished = false;
    const started = Date.now();
    const result = { server, resolution, candidates: [], errors: [], errorKinds: [], completed: false, timedOut: false, attempts: 1, waitedMs: 0, waitLimitMs: budget };
    const finish = timedOut => {
      if (finished) return;
      finished = true;
      result.timedOut = timedOut;
      result.waitedMs = Date.now() - started;
      clearTimeout(timer);
      if (peer) {
        peer.onicecandidate = null;
        peer.onicecandidateerror = null;
        peer.onicegatheringstatechange = null;
        try { peer.close(); } catch (_) {}
      }
      resolve(result);
    };
    if (budget <= 0) { finish(true); return; }
    timer = setTimeout(() => finish(true), budget);
    try {
      peer = new RTCPeerConnection({ iceServers: [{ urls }], iceTransportPolicy: "all" });
      peer.onicecandidate = event => {
        if (!event.candidate) { result.completed = true; finish(false); return; }
        const candidate = event.candidate;
        const parts = (candidate.candidate || "").trim().split(/\s+/);
        const typeIndex = parts.indexOf("typ");
        const item = {
          address: candidate.address || parts[4] || "",
          type: candidate.type || (typeIndex >= 0 ? parts[typeIndex + 1] : ""),
          protocol: candidate.protocol || (parts[2] || "").toLowerCase()
        };
        if (!result.candidates.some(x => x.address === item.address && x.type === item.type && x.protocol === item.protocol)) {
          result.candidates.push(item);
        }
      };
      peer.onicecandidateerror = event => {
        result.errors.push(Number(event.errorCode) || 0);
        // Classify in memory; do not retain browser messages, URLs or local IPs.
        const text = String(event.errorText || "").toLowerCase();
        const kind = /host lookup|name resolution|resolve/.test(text) ? "name_resolution" :
          /timed?\s*out|timeout/.test(text) ? "timeout" :
          /unreachable/.test(text) ? "unreachable" : "transport";
        if (!result.errorKinds.includes(kind)) result.errorKinds.push(kind);
      };
      peer.onicegatheringstatechange = () => {
        if (peer.iceGatheringState === "complete") { result.completed = true; finish(false); }
      };
      peer.createDataChannel("guard-probe");
      Promise.resolve(peer.createOffer()).then(offer => peer.setLocalDescription(offer))
        .catch(() => { result.errors.push(-1); finish(false); });
    } catch (_) { result.errors.push(-2); finish(false); }
  });
  const probes = await Promise.all(servers.map(definition => probeOnce(definition, Math.min(timeoutMs, remaining()))));
  const hasReflexive = probe => probe.candidates.some(candidate => candidate.type === "srflx");
  // If UDP worked for one node, retry just the missing node once with a fresh
  // peer/socket, after the initial peers have closed. Keep ALL prior evidence.
  // A wholly unresponsive/blocked environment is not retried or marked safe.
  if (probes.some(hasReflexive)) {
    for (let index = 0; index < probes.length; index++) {
      const original = probes[index];
      if (hasReflexive(original) || original.errors.some(code => code < 0)) continue;
      if (remaining() <= 0) continue;
      const retry = await probeOnce(servers[index], Math.min(retryTimeoutMs, remaining()));
      for (const candidate of retry.candidates) {
        if (!original.candidates.some(item => item.address === candidate.address &&
          item.type === candidate.type && item.protocol === candidate.protocol)) {
          original.candidates.push(candidate);
        }
      }
      original.errors = [...new Set([...original.errors, ...retry.errors])];
      original.errorKinds = [...new Set([...original.errorKinds, ...retry.errorKinds])];
      original.completed = retry.completed;
      original.timedOut = retry.timedOut;
      original.attempts = 2;
      original.waitedMs += retry.waitedMs;
      original.waitLimitMs += retry.waitLimitMs;
    }
  }
  return { supported: true, probes };
}
globalThis.runGuardWebRTCProbe = runGuardWebRTCProbe;
