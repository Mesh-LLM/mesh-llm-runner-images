using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace MeshWindows
{
    // Assign a suspended child before it can launch descendants. Neither
    // breakaway flag is enabled; cancellation affects only this unnamed job.
    public sealed class TaskProcess : IDisposable
    {
        private IntPtr job;
        private IntPtr process;
        private bool exited;
        private int exitCode;

        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes
        {
            public int Length;
            public IntPtr Descriptor;
            public int Inherit;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct StartupInfo
        {
            public int Size;
            public string Reserved, Desktop, Title;
            public uint X, Y, XSize, YSize, XChars, YChars, Fill, Flags;
            public short Show, ReservedBytes;
            public IntPtr ReservedData, Input, Output, Error;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ProcessInformation
        {
            public IntPtr Process, Thread;
            public uint ProcessId, ThreadId;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct BasicLimits
        {
            public long ProcessTime, JobTime;
            public uint Flags;
            public UIntPtr MinWorkingSet, MaxWorkingSet;
            public uint ActiveLimit;
            public UIntPtr Affinity;
            public uint Priority, Scheduling;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IoCounters
        {
            public ulong Reads, Writes, Other, ReadBytes, WriteBytes, OtherBytes;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ExtendedLimits
        {
            public BasicLimits Basic;
            public IoCounters Io;
            public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct Accounting
        {
            public long UserTime, KernelTime, PeriodUserTime, PeriodKernelTime;
            public uint Faults, TotalProcesses, ActiveProcesses, TerminatedProcesses;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(IntPtr job, int kind, ref ExtendedLimits value, uint size);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool QueryInformationJobObject(IntPtr job, int kind, out Accounting value, uint size, IntPtr returned);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateJobObject(IntPtr job, uint code);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateProcess(IntPtr process, uint code);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(string name, uint access, uint share,
            ref SecurityAttributes attributes, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CreateProcess(string application, StringBuilder arguments,
            IntPtr processAttributes, IntPtr threadAttributes, bool inherit, uint flags,
            IntPtr environment, string directory, ref StartupInfo startup, out ProcessInformation result);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetExitCodeProcess(IntPtr process, out uint code);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);

        private static void Require(bool success)
        {
            if (!success) throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        private static SafeFileHandle Open(string path, uint access, uint disposition)
        {
            SecurityAttributes attributes = new SecurityAttributes();
            attributes.Length = Marshal.SizeOf(typeof(SecurityAttributes));
            attributes.Inherit = 1;
            SafeFileHandle handle = CreateFile(path, access, 3, ref attributes, disposition, 0x80, IntPtr.Zero);
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            return handle;
        }

        public TaskProcess(string executable, string arguments, string stdout, string stderr)
        {
            ProcessInformation info = new ProcessInformation();
            try
            {
                job = CreateJobObject(IntPtr.Zero, null);
                if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
                ExtendedLimits limits = new ExtendedLimits();
                limits.Basic.Flags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
                Require(SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf(typeof(ExtendedLimits))));
                using (SafeFileHandle input = Open("NUL", 0x80000000, 3))
                using (SafeFileHandle output = Open(stdout, 0x40000000, 2))
                using (SafeFileHandle error = Open(stderr, 0x40000000, 2))
                {
                    StartupInfo startup = new StartupInfo();
                    startup.Size = Marshal.SizeOf(typeof(StartupInfo));
                    startup.Flags = 0x100; // STARTF_USESTDHANDLES
                    startup.Input = input.DangerousGetHandle();
                    startup.Output = output.DangerousGetHandle();
                    startup.Error = error.DangerousGetHandle();
                    Require(CreateProcess(executable, new StringBuilder("\"" + executable + "\" " + arguments),
                        IntPtr.Zero, IntPtr.Zero, true, 0x08000004, IntPtr.Zero, null, ref startup, out info));
                    process = info.Process;
                    Require(AssignProcessToJobObject(job, process));
                    if (ResumeThread(info.Thread) == UInt32.MaxValue)
                        throw new Win32Exception(Marshal.GetLastWin32Error());
                }
            }
            catch
            {
                // A failed assignment must not leave an uncontained suspended child.
                if (process != IntPtr.Zero) TerminateProcess(process, 1);
                Dispose();
                throw;
            }
            finally
            {
                if (info.Thread != IntPtr.Zero) CloseHandle(info.Thread);
            }
        }

        public bool HasExited
        {
            get
            {
                if (!exited && process != IntPtr.Zero)
                {
                    uint wait = WaitForSingleObject(process, 0);
                    if (wait == UInt32.MaxValue) throw new Win32Exception(Marshal.GetLastWin32Error());
                    if (wait == 0)
                    {
                        uint code;
                        Require(GetExitCodeProcess(process, out code));
                        exitCode = unchecked((int)code);
                        exited = true;
                        CloseHandle(process);
                        process = IntPtr.Zero;
                    }
                }
                return exited;
            }
        }

        public bool IsTreeEmpty
        {
            get
            {
                bool rootExited = HasExited;
                Accounting accounting;
                Require(QueryInformationJobObject(job, 1, out accounting,
                    (uint)Marshal.SizeOf(typeof(Accounting)), IntPtr.Zero));
                return accounting.ActiveProcesses == 0 && rootExited;
            }
        }

        public int ExitCode
        {
            get
            {
                if (!HasExited) throw new InvalidOperationException("Task process has not exited");
                return exitCode;
            }
        }

        public void Stop()
        {
            if (job == IntPtr.Zero) return;
            Require(TerminateJobObject(job, 1));
            Stopwatch wait = Stopwatch.StartNew();
            while (!IsTreeEmpty && wait.ElapsedMilliseconds < 10000) Thread.Sleep(25);
            if (!IsTreeEmpty) throw new TimeoutException("Task process tree did not stop");
        }

        public void Dispose()
        {
            try { if (job != IntPtr.Zero && process != IntPtr.Zero) Stop(); }
            finally
            {
                if (process != IntPtr.Zero) { CloseHandle(process); process = IntPtr.Zero; }
                if (job != IntPtr.Zero) { CloseHandle(job); job = IntPtr.Zero; }
            }
        }
    }
}
