// launcher.cs - self-extracting stub for the EclipVPN installer (Stage 3).
//
// Compiled by build-exe.ps1 into a single winexe with bundle.zip embedded as a
// resource. On launch it extracts the bundle (installer scripts + SSH.NET DLL +
// the ~88MB static-binary payload + the EclipVPN source tree) into a temp dir,
// then runs the WinForms GUI (install-eclipvpn-gui.ps1) via powershell -STA.
//
// This gives the "one .exe, double-click, install" experience without bundling a
// Python/Qt runtime: PowerShell and .NET are already on every Windows 10/11 box.

using System;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Diagnostics;
using System.Windows.Forms;

static class Launcher
{
    [STAThread]
    static int Main()
    {
        try
        {
            string baseDir = Path.Combine(Path.GetTempPath(), "EclipVPN-Installer");
            Directory.CreateDirectory(baseDir);

            // Extract the embedded bundle, overwriting (idempotent across runs).
            Assembly asm = Assembly.GetExecutingAssembly();
            using (Stream s = asm.GetManifestResourceStream("bundle.zip"))
            {
                if (s == null) throw new Exception("embedded bundle.zip resource not found");
                using (ZipArchive zip = new ZipArchive(s, ZipArchiveMode.Read))
                {
                    foreach (ZipArchiveEntry entry in zip.Entries)
                    {
                        string rel = entry.FullName.Replace('/', Path.DirectorySeparatorChar)
                                                   .Replace('\\', Path.DirectorySeparatorChar);
                        string dest = Path.Combine(baseDir, rel);
                        // Directory entries have an empty Name (robust regardless of
                        // whether the zip used '/' or '\' as the separator - .NET
                        // Framework's ZipFile writes '\', which broke a '/'-only check).
                        if (string.IsNullOrEmpty(entry.Name))
                        {
                            Directory.CreateDirectory(dest);
                            continue;
                        }
                        Directory.CreateDirectory(Path.GetDirectoryName(dest));
                        entry.ExtractToFile(dest, true);
                    }
                }
            }

            string gui = Path.Combine(baseDir, "windows-installer", "install-eclipvpn-gui.ps1");
            if (!File.Exists(gui)) throw new Exception("GUI script missing after extraction: " + gui);

            // powershell.exe is a console app; launched from a winexe it would
            // pop a console window next to the WPF GUI. CreateNoWindow + hidden
            // style suppress that console (the WPF window is unaffected).
            ProcessStartInfo psi = new ProcessStartInfo(
                "powershell.exe",
                "-STA -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + gui + "\"");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WindowStyle = ProcessWindowStyle.Hidden;
            Process p = Process.Start(psi);
            p.WaitForExit();
            return p.ExitCode;
        }
        catch (Exception e)
        {
            MessageBox.Show(e.ToString(), "EclipVPN Installer - error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
