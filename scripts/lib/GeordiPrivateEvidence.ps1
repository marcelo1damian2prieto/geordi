if (-not ('GeordiPrivateCaptureScanResult' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;

public sealed class GeordiPrivateCaptureScanResult {
    public long ByteCount { get; set; }
    public string Sha256 { get; set; }
    public string[] Matches { get; set; }
}

public static class GeordiPrivateCaptureScanner {
    public static GeordiPrivateCaptureScanResult Scan(string path, string[] needles, long maximumBytes) {
        if (String.IsNullOrWhiteSpace(path) || needles == null || needles.Length == 0 || maximumBytes < 1)
            throw new InvalidDataException("Private capture scan input is invalid.");

        var patterns = new HashSet<string>(StringComparer.Ordinal);
        long patternCharacters = 0;
        foreach (var needle in needles) {
            if (String.IsNullOrEmpty(needle) || needle.Length > 131072)
                throw new InvalidDataException("Private capture scan needle is invalid.");
            patterns.Add(needle);
            patternCharacters += needle.Length;
        }
        if (patterns.Count > 2048 || patternCharacters > 4L * 1024 * 1024)
            throw new InvalidDataException("Private capture scan pattern inventory exceeded its bound.");
        var largestNeedle = 0;
        foreach (var needle in patterns) largestNeedle = Math.Max(largestNeedle, needle.Length);

        var encodings = new Encoding[] { new UTF8Encoding(false, false), Encoding.Latin1, Encoding.Unicode };
        var decoders = new Decoder[encodings.Length];
        var charBuffers = new char[encodings.Length][];
        var tails = new string[encodings.Length];
        for (var i = 0; i < encodings.Length; i++) {
            decoders[i] = encodings[i].GetDecoder();
            charBuffers[i] = new char[encodings[i].GetMaxCharCount(65536)];
            tails[i] = String.Empty;
        }

        var matched = new HashSet<string>(StringComparer.Ordinal);
        var bytes = new byte[65536];
        long total = 0;
        using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read)) {
            var initialLength = stream.Length;
            if (initialLength <= 0 || initialLength > maximumBytes)
                throw new InvalidDataException("Private capture size is outside its bound.");
            using (var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256)) {
                int read;
                while ((read = stream.Read(bytes, 0, bytes.Length)) > 0) {
                    total += read;
                    if (total > maximumBytes || total > initialLength)
                        throw new InvalidDataException("Private capture changed or exceeded its bound.");
                    hash.AppendData(bytes, 0, read);
                    for (var i = 0; i < decoders.Length; i++) {
                        var chars = decoders[i].GetChars(bytes, 0, read, charBuffers[i], 0, false);
                        var decoded = new string(charBuffers[i], 0, chars);
                        var window = tails[i] + decoded;
                        foreach (var needle in patterns) {
                            if (!matched.Contains(needle) && window.IndexOf(needle, StringComparison.Ordinal) >= 0)
                                matched.Add(needle);
                        }
                        var tailLength = Math.Min(Math.Max(0, largestNeedle - 1), window.Length);
                        tails[i] = tailLength == 0 ? String.Empty : window.Substring(window.Length - tailLength, tailLength);
                    }
                }
                for (var i = 0; i < decoders.Length; i++) {
                    var chars = decoders[i].GetChars(Array.Empty<byte>(), 0, 0, charBuffers[i], 0, true);
                    var decoded = new string(charBuffers[i], 0, chars);
                    var window = tails[i] + decoded;
                    foreach (var needle in patterns) {
                        if (!matched.Contains(needle) && window.IndexOf(needle, StringComparison.Ordinal) >= 0)
                            matched.Add(needle);
                    }
                }
                if (total != initialLength || stream.Length != initialLength)
                    throw new InvalidDataException("Private capture was incomplete or changed during scanning.");
                return new GeordiPrivateCaptureScanResult {
                    ByteCount = total,
                    Sha256 = BitConverter.ToString(hash.GetHashAndReset()).Replace("-", String.Empty).ToLowerInvariant(),
                    Matches = new List<string>(matched).ToArray()
                };
            }
        }
    }
}
'@
}

function Get-GeordiPrivateCaptureLimit {
    param([Parameter(Mandatory)][string] $Channel)
    # Runtime logs can span the complete ordered M19 gate sequence. Keep large
    # channels within the existing 512 MiB per-channel expansion budget and scan
    # them incrementally so working memory stays independent of capture size.
    if ($Channel -in @('backend','otel','collector')) { return [long](512MB) }
    if ($Channel -ceq 'tempo') { return [long](160MB) }
    return [long](64MB)
}

function Invoke-GeordiPrivateCaptureScan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string[]] $Needles,
        [Parameter(Mandatory)][long] $MaximumBytes
    )
    return [GeordiPrivateCaptureScanner]::Scan($Path, $Needles, $MaximumBytes)
}
