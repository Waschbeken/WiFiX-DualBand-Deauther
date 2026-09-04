#Requires -Version 5.1
<#
    PowerBench.ps1

    Gemeinsame Rechenlast fuer den Leistungstest (Test-PowerPerformance.ps1)
    und die automatische Kalibrierung (Invoke-PowerCalibration.ps1).

    Die Last laeuft in C#, damit alle Kerne echt ausgelastet werden - eine
    PowerShell-Schleife waere dafuer zu langsam und zu unregelmaessig.
    Gemessen wird der Durchsatz (Durchlaeufe je Sekunde); das ist ein
    relativer Wert, der nur im Vergleich untereinander Sinn ergibt.
#>

if (-not ('PowerProfileSwitcher.Bench' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Threading;

namespace PowerProfileSwitcher {
    public static class Bench {

        // Eine Runde Gleitkomma-Arbeit. Das Ergebnis wird zurueckgegeben,
        // damit der Compiler die Schleife nicht wegoptimiert.
        private static double Work(int rounds) {
            double acc = 1.0;
            for (int i = 1; i <= rounds; i++) {
                acc += Math.Sqrt(i) * Math.Sin(i * 0.001);
                if (acc > 1e12) { acc = 1.0; }
            }
            return acc;
        }

        private const int RoundsPerIteration = 200000;

        // Durchlaeufe je Sekunde auf einem Kern.
        public static double SingleThread(int milliseconds) {
            Work(RoundsPerIteration); // Aufwaermen (JIT)
            long iterations = 0;
            Stopwatch sw = Stopwatch.StartNew();
            while (sw.ElapsedMilliseconds < milliseconds) {
                Work(RoundsPerIteration);
                iterations++;
            }
            sw.Stop();
            return iterations * 1000.0 / sw.Elapsed.TotalMilliseconds;
        }

        // Durchlaeufe je Sekunde ueber alle logischen Kerne.
        public static double MultiThread(int milliseconds) {
            int threadCount = Environment.ProcessorCount;
            long total = 0;
            Thread[] threads = new Thread[threadCount];
            Stopwatch sw = Stopwatch.StartNew();

            for (int t = 0; t < threadCount; t++) {
                threads[t] = new Thread(delegate() {
                    long local = 0;
                    while (sw.ElapsedMilliseconds < milliseconds) {
                        Work(RoundsPerIteration);
                        local++;
                    }
                    Interlocked.Add(ref total, local);
                });
                threads[t].IsBackground = true;
                threads[t].Start();
            }

            for (int t = 0; t < threadCount; t++) { threads[t].Join(); }
            sw.Stop();
            return total * 1000.0 / sw.Elapsed.TotalMilliseconds;
        }
    }
}
'@ -ErrorAction Stop
}

# Fuehrt die Mehrkern-Last in mehreren Abschnitten aus und ruft zwischendurch
# den uebergebenen Messblock auf - so wird der Verbrauch WAEHREND der Last
# erfasst und nicht erst danach.
function Invoke-BenchmarkRun {
    param(
        [int]$Milliseconds = 6000,
        [int]$Chunks = 3,
        [scriptblock]$OnSample = $null
    )

    $chunkMs = [int]($Milliseconds / [Math]::Max(1, $Chunks))
    $parts = @()
    for ($i = 0; $i -lt $Chunks; $i++) {
        $parts += [PowerProfileSwitcher.Bench]::MultiThread($chunkMs)
        if ($OnSample) { & $OnSample }
    }
    return ($parts | Measure-Object -Average).Average
}
