"use strict";
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const assert = require("node:assert/strict");
const source = fs.readFileSync(path.join(__dirname, "../windows/local/probes/webrtc.js"), "utf8");
let passed = 0, mode = "ok", closed = 0, lastConfiguration, created = 0;
class FakePeer {
  constructor(configuration) { this.iceGatheringState = "new"; lastConfiguration = configuration; this.index=created++; }
  createDataChannel() {}
  async createOffer() { if (mode === "offer-error") throw new Error("fixture"); return {}; }
  async setLocalDescription() {
    if (mode === "timeout") return;
    setTimeout(() => {
      if (!this.onicecandidate) return;
      if (mode === "stun-errors") {
        this.onicecandidateerror({errorCode:701,errorText:"STUN host lookup received error private.example"});
        this.onicecandidateerror({errorCode:701,errorText:"STUN request timed out private-address"});
        this.onicecandidate({candidate:null});
        return;
      }
      if (mode === "one-missing" && this.index === 0) {
        this.onicecandidate({candidate:{address:"203.0.113.99",type:"host",protocol:"udp"}});
        this.onicecandidate({candidate:null});
        return;
      }
      this.onicecandidate({candidate:{address:"203.0.113.10",type:"srflx",protocol:"udp"}});
      this.onicecandidate({candidate:{address:"fixture.local",type:"host",protocol:"udp"}});
      this.onicecandidate({candidate:null});
    }, 1);
  }
  close() { closed++; }
}
const context = vm.createContext({RTCPeerConnection:FakePeer, setTimeout, clearTimeout});
vm.runInContext(source, context);
async function run() {
  let result = await context.runGuardWebRTCProbe({timeoutMs:50});
  assert.equal(result.supported,true); passed++;
  assert.equal(result.probes.length,2); passed++;
  assert.equal(result.probes[0].candidates[0].type,"srflx"); passed++;
  assert.equal(result.probes[0].completed,true); passed++;
  assert.equal(closed,2); passed++;
  result=await context.runGuardWebRTCProbe({timeoutMs:50,servers:[{
    id:"stun:stun.l.google.com:19302",urls:["stun:198.51.100.20:19302"],resolution:"proxy_doh"
  }]});
  assert.equal(result.probes[0].server,"stun:stun.l.google.com:19302"); passed++;
  assert.equal(result.probes[0].resolution,"proxy_doh"); passed++;
  assert.equal(lastConfiguration.iceServers[0].urls[0],"stun:198.51.100.20:19302"); passed++;
  assert.equal(lastConfiguration.iceTransportPolicy,"all"); passed++;
  mode="one-missing";created=0;
  result=await context.runGuardWebRTCProbe({timeoutMs:50,retryTimeoutMs:10});
  assert.equal(result.probes[0].attempts,2); passed++;
  assert.equal(result.probes[1].attempts,1); passed++;
  assert.equal(result.probes[0].candidates.some(item=>item.type==="srflx"),true); passed++;
  assert.equal(result.probes[0].candidates.some(item=>item.address==="203.0.113.99"),true); passed++;
  mode="timeout";
  result=await context.runGuardWebRTCProbe({timeoutMs:5});
  assert.equal(result.probes[0].timedOut,true); passed++;
  assert.equal(result.probes[0].candidates.length,0); passed++;
  assert.equal(result.probes[0].waitLimitMs,5); passed++;
  assert.equal(result.probes[0].waitedMs >= 0,true); passed++;
  mode="timeout";
  result=await context.runGuardWebRTCProbe({timeoutMs:50,totalTimeoutMs:4});
  assert.equal(result.probes.every(p=>p.waitLimitMs<=4),true); passed++;
  assert.equal(result.probes.every(p=>p.timedOut),true); passed++;
  const beforeExpired=created;
  result=await context.runGuardWebRTCProbe({timeoutMs:50,totalTimeoutMs:50,deadlineEpochMs:Date.now()-1});
  assert.equal(created,beforeExpired); passed++;
  assert.equal(result.probes.every(p=>p.timedOut && p.waitLimitMs===0),true); passed++;
  result=await context.runGuardWebRTCProbe({timeoutMs:50,totalTimeoutMs:50,deadlineEpochMs:Date.now()+4});
  assert.equal(result.probes.every(p=>p.waitLimitMs<=4),true); passed++;
  mode="offer-error";
  result=await context.runGuardWebRTCProbe({timeoutMs:50});
  assert.equal(result.probes[0].errors[0],-1); passed++;
  mode="stun-errors";
  result=await context.runGuardWebRTCProbe({timeoutMs:50});
  assert.equal(result.probes[0].errorKinds.includes("name_resolution"),true); passed++;
  assert.equal(result.probes[0].errorKinds.includes("timeout"),true); passed++;
  assert.equal(JSON.stringify(result).includes("private"),false); passed++;
  context.RTCPeerConnection=undefined;
  result=await context.runGuardWebRTCProbe();
  assert.equal(result.supported,false); passed++;
  console.log("Passed "+passed+" JavaScript browser-probe assertions; no network or media permissions were used.");
}
run().catch(error => { console.error(error); process.exitCode=1; });
