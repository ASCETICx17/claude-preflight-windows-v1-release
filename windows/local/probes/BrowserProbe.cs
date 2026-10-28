using System;
using System.IO;
using System.Text;
using System.Diagnostics;
using System.Collections.Generic;
using System.Net.WebSockets;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace ClaudeGuardProbe {
    public sealed class BrowserResult {
        public string Json { get; set; }
        public bool CleanupComplete { get; set; }
    }
    public static class BrowserClient {
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr a, string name);
        [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length);
        [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        [StructLayout(LayoutKind.Sequential)] struct BasicLimit {
            public long ProcessUserTime, JobUserTime;
            public uint Flags;
            public UIntPtr MinWorkingSet, MaxWorkingSet;
            public uint ActiveProcesses;
            public UIntPtr Affinity;
            public uint Priority, Scheduling;
        }
        [StructLayout(LayoutKind.Sequential)] struct IoCounters {
            public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes;
        }
        [StructLayout(LayoutKind.Sequential)] struct ExtendedLimit {
            public BasicLimit Basic;
            public IoCounters Io;
            public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
        }
        static IntPtr NewJob() {
            IntPtr job=CreateJobObject(IntPtr.Zero, null);
            if(job==IntPtr.Zero) throw new InvalidOperationException("Cannot create probe job.");
            var limits=new ExtendedLimit();
            limits.Basic.Flags=0x2000; // Kill only this dedicated browser job when its handle closes.
            int size=Marshal.SizeOf(limits);
            IntPtr ptr=Marshal.AllocHGlobal(size);
            try {
                Marshal.StructureToPtr(limits,ptr,false);
                if(!SetInformationJobObject(job,9,ptr,(uint)size)) { CloseHandle(job); throw new InvalidOperationException("Cannot configure probe job."); }
            } finally { Marshal.FreeHGlobal(ptr); }
            return job;
        }
        static string Quote(string text) {
            if(text.IndexOfAny(new[]{'"','\r','\n'})>=0) throw new ArgumentException("Invalid probe argument.");
            return "\""+text.TrimEnd('\\')+"\"";
        }
        static Dictionary<string,object> Object(object value) {
            return (Dictionary<string,object>)value;
        }
        static async Task<Dictionary<string,object>> Command(ClientWebSocket socket, JavaScriptSerializer json,
                int id, string method, object parameters, string session, CancellationToken token) {
            var message=new Dictionary<string,object>{{"id",id},{"method",method},{"params",parameters}};
            if(session!=null) message["sessionId"]=session;
            byte[] send=Encoding.UTF8.GetBytes(json.Serialize(message));
            await socket.SendAsync(new ArraySegment<byte>(send),WebSocketMessageType.Text,true,token).ConfigureAwait(false);
            byte[] buffer=new byte[16384];
            while(true) {
                using(var stream=new MemoryStream()) {
                    WebSocketReceiveResult read;
                    do {
                        read=await socket.ReceiveAsync(new ArraySegment<byte>(buffer),token).ConfigureAwait(false);
                        if(read.MessageType==WebSocketMessageType.Close) throw new IOException("Probe connection closed.");
                        stream.Write(buffer,0,read.Count);
                        if(stream.Length>1048576) throw new IOException("Probe response too large.");
                    } while(!read.EndOfMessage);
                    var response=json.Deserialize<Dictionary<string,object>>(Encoding.UTF8.GetString(stream.ToArray()));
                    if(!response.ContainsKey("id") || Convert.ToInt32(response["id"])!=id) continue;
                    if(response.ContainsKey("error")) throw new InvalidOperationException("Probe command failed.");
                    return Object(response["result"]);
                }
            }
        }
        static void DeleteOwnedTree(string path, string root) {
            string full=Path.GetFullPath(path);
            if(!full.Equals(root,StringComparison.OrdinalIgnoreCase) &&
               !full.StartsWith(root+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase))
                throw new IOException("Cleanup path outside probe profile.");
            foreach(string entry in Directory.GetFileSystemEntries(full)) {
                var attributes=File.GetAttributes(entry);
                bool directory=(attributes&FileAttributes.Directory)!=0;
                bool link=(attributes&FileAttributes.ReparsePoint)!=0;
                if(directory && !link) DeleteOwnedTree(entry,root);
                else if(directory) Directory.Delete(entry);
                else { if((attributes&FileAttributes.ReadOnly)!=0) File.SetAttributes(entry,attributes&~FileAttributes.ReadOnly); File.Delete(entry); }
            }
            Directory.Delete(full);
        }
        public static BrowserResult Run(string executable,string proxy,string page,int seconds) {
            return RunAsync(executable,proxy,page,seconds,null).GetAwaiter().GetResult();
        }
        public static BrowserResult Run(string executable,string proxy,string page,int seconds,string optionsJson) {
            return RunAsync(executable,proxy,page,seconds,optionsJson).GetAwaiter().GetResult();
        }
        static async Task<BrowserResult> RunAsync(string executable,string proxy,string page,int seconds,string optionsJson) {
            var watch=Stopwatch.StartNew();
            string stage="BrowserStart";
            string temp=Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar);
            string profile=Path.Combine(temp,"ClaudeGuardProbe-"+Guid.NewGuid().ToString("N"));
            if(!profile.StartsWith(temp+Path.DirectorySeparatorChar+"ClaudeGuardProbe-",StringComparison.OrdinalIgnoreCase))
                throw new IOException("Invalid probe profile.");
            Directory.CreateDirectory(profile);
            var output=new BrowserResult();
            IntPtr job=IntPtr.Zero;
            Process process=null;
            ClientWebSocket socket=null;
            try {
                job=NewJob();
                var info=new ProcessStartInfo(executable);
                info.UseShellExecute=false; info.CreateNoWindow=true; info.WindowStyle=ProcessWindowStyle.Hidden;
                info.RedirectStandardError=true; info.RedirectStandardOutput=true;
                info.Arguments="--headless=new --disable-gpu --no-first-run --no-default-browser-check "+
                    "--disable-background-networking --disable-component-update --disable-sync --disable-extensions "+
                    "--inprivate --remote-debugging-address=127.0.0.1 --remote-debugging-port=0 "+
                    "--user-data-dir="+Quote(profile)+" --proxy-server="+Quote(proxy)+" about:blank";
                process=Process.Start(info);
                if(!AssignProcessToJobObject(job,process.Handle)) { process.Kill(); throw new InvalidOperationException("Cannot contain probe process."); }
                // Drain output in memory; never log browser diagnostics or user paths.
                var stderr=process.StandardError.ReadToEndAsync();
                var stdout=process.StandardOutput.ReadToEndAsync();
                int remaining=(int)Math.Max(1,seconds*1000L-watch.ElapsedMilliseconds);
                using(var timeout=new CancellationTokenSource(remaining)) {
                    string active=Path.Combine(profile,"DevToolsActivePort");
                    string[] lines=null;
                    while(!timeout.IsCancellationRequested) {
                        if(process.HasExited) throw new IOException("Probe browser exited.");
                        if(File.Exists(active)) {
                            try { lines=File.ReadAllLines(active); if(lines.Length>=2) break; } catch(IOException) {}
                        }
                        await Task.Delay(50,timeout.Token).ConfigureAwait(false);
                    }
                    int port;
                    if(lines==null || lines.Length<2 || !Int32.TryParse(lines[0],out port) || port<1024 || port>65535 ||
                       !System.Text.RegularExpressions.Regex.IsMatch(lines[1],@"^/devtools/browser/[a-zA-Z0-9-]+$"))
                        throw new IOException("Invalid local probe endpoint.");
                    socket=new ClientWebSocket();
                    stage="DebugChannel";
                    socket.Options.Proxy=new System.Net.WebProxy();
                    await socket.ConnectAsync(new Uri("ws://127.0.0.1:"+port+lines[1]),timeout.Token).ConfigureAwait(false);
                    var json=new JavaScriptSerializer { MaxJsonLength=1048576 };
                    var options=optionsJson==null ? new Dictionary<string,object>() : json.Deserialize<Dictionary<string,object>>(optionsJson);
                    var target=await Command(socket,json,1,"Target.createTarget",new {url="about:blank"},null,timeout.Token).ConfigureAwait(false);
                    var attached=await Command(socket,json,2,"Target.attachToTarget",new {targetId=(string)target["targetId"],flatten=true},null,timeout.Token).ConfigureAwait(false);
                    string session=(string)attached["sessionId"];
                    await Command(socket,json,3,"Page.enable",new {},session,timeout.Token).ConfigureAwait(false);
                    stage="LocalPage";
                    await Command(socket,json,4,"Page.navigate",new {url=new Uri(Path.GetFullPath(page)).AbsoluteUri},session,timeout.Token).ConfigureAwait(false);
                    // Startup and local-page loading consume the same budget as ICE.
                    // Reserve one second to return the result before CDP is cancelled.
                    remaining=(int)(seconds*1000L-watch.ElapsedMilliseconds-1000);
                    if(remaining<=0) throw new TimeoutException("Probe startup exhausted the budget.");
                    options["deadlineEpochMs"]=(DateTime.UtcNow-new DateTime(1970,1,1,0,0,0,DateTimeKind.Utc)).TotalMilliseconds+remaining;
                    string probeOptions=json.Serialize(options);
                    stage="IceGathering";
                    string expression="new Promise((resolve,reject)=>{let n=0;const timer=setInterval(()=>{"+
                        "if(typeof globalThis.runGuardWebRTCProbe==='function'){clearInterval(timer);"+
                        "Promise.resolve(globalThis.runGuardWebRTCProbe("+probeOptions+")).then(resolve,reject);}"+
                        "else if(++n>200){clearInterval(timer);reject(new Error('Probe page not ready'));}},25);})";
                    var evaluated=await Command(socket,json,5,"Runtime.evaluate",new {expression,awaitPromise=true,returnByValue=true},session,timeout.Token).ConfigureAwait(false);
                    if(evaluated.ContainsKey("exceptionDetails")) throw new InvalidOperationException("Probe script failed.");
                    var result=Object(evaluated["result"]);
                    if(!result.ContainsKey("value")) throw new IOException("Probe returned no result.");
                    output.Json=json.Serialize(result["value"]);
                }
            } catch(Exception error) {
                error.Data["CSProbeStage"]=stage;
                throw;
            } finally {
                if(socket!=null) {
                    try {
                        using(var stop=new CancellationTokenSource(1500)) {
                            var bytes=Encoding.UTF8.GetBytes("{\"id\":99,\"method\":\"Browser.close\"}");
                            if(socket.State==WebSocketState.Open) socket.SendAsync(new ArraySegment<byte>(bytes),WebSocketMessageType.Text,true,stop.Token).GetAwaiter().GetResult();
                        }
                    } catch {} finally { socket.Dispose(); }
                }
                if(job!=IntPtr.Zero) CloseHandle(job);
                if(process!=null) {
                    try { if(!process.WaitForExit(2000)) process.Kill(); } catch {}
                    process.Dispose();
                }
                for(int attempt=0;attempt<8;attempt++) {
                    try { if(Directory.Exists(profile)) DeleteOwnedTree(profile,profile); output.CleanupComplete=true; break; }
                    catch { Thread.Sleep(150); }
                }
            }
            return output;
        }
    }
}
