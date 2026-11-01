# SPDX-License-Identifier: MIT
#
# Strict JSON reading for configuration files. ConvertFrom-Json is not used on purpose: it turns date-like strings
# into DateTime, merges keys that differ only by case and keeps the last of two equal keys silently. Here:
#   - objects become ordered dictionaries with case-sensitive keys; a key that appears twice is an error;
#   - integers become [long] (larger ones [double]), other numbers [double], strings [string], booleans [bool],
#     arrays [object[]], null $null;
#   - comments and trailing commas are errors (unless -Lenient: VST3 moduleinfo.json files have trailing commas).
#   ConvertFrom-HarnessJson -Text <json> [-Lenient]   returns the value; throws "JSON: ..." on any problem
#   ConvertTo-HarnessJsonText -Value <v>   compact or indented JSON text (stable key order), for generated files

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ('HarnessJson' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.Text.Json;

public static class HarnessJson {
    public static object Parse(string text, bool lenient) {
        var opts = new JsonDocumentOptions { AllowTrailingCommas = lenient, CommentHandling = lenient ? JsonCommentHandling.Skip : JsonCommentHandling.Disallow, MaxDepth = 64 };
        JsonDocument doc;
        try { doc = JsonDocument.Parse(text, opts); }
        catch (JsonException e) { throw new FormatException("JSON: " + e.Message); }
        using (doc) return Convert(doc.RootElement, "$");
    }

    // JSON string literal; control characters as \u escapes, everything else (non-ASCII included) as it is.
    public static string Quote(string s) {
        var sb = new System.Text.StringBuilder("\"");
        foreach (char c in s) {
            switch (c) {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                default: if (c < 0x20 || c == 0x7f) sb.Append("\\u").Append(((int)c).ToString("x4")); else sb.Append(c); break;
            }
        }
        return sb.Append('"').ToString();
    }
    static object Convert(JsonElement e, string path) {
        switch (e.ValueKind) {
            case JsonValueKind.Object: {
                var d = new OrderedDictionary(StringComparer.Ordinal);
                foreach (var p in e.EnumerateObject()) {
                    if (d.Contains(p.Name)) throw new FormatException("JSON: duplicate key '" + p.Name + "' in " + path);
                    d.Add(p.Name, Convert(p.Value, path + "." + p.Name));
                }
                return d;
            }
            case JsonValueKind.Array: {
                var list = new List<object>(); int i = 0;
                foreach (var x in e.EnumerateArray()) list.Add(Convert(x, path + "[" + (i++) + "]"));
                return list.ToArray();
            }
            case JsonValueKind.String: return e.GetString();
            case JsonValueKind.Number: { long l; if (e.TryGetInt64(out l)) return l; return e.GetDouble(); }
            case JsonValueKind.True: return true;
            case JsonValueKind.False: return false;
            default: return null;
        }
    }
}
'@
}

function ConvertFrom-HarnessJson([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [switch]$Lenient) {
    try { [HarnessJson]::Parse($Text, [bool]$Lenient) } catch { throw ($_.Exception.InnerException ?? $_.Exception).Message }
}

# Writes dictionaries, objects ([pscustomobject], properties in their order), arrays, strings, numbers and booleans
# as JSON (dictionary keys in their own order).
function ConvertTo-HarnessJsonText {
    param([AllowNull()]$Value, [int]$Indent = 0, [int]$Level = 0)
    $pad = { param($n) ' ' * ($Indent * $n) }
    $nl = $Indent ? "`n" : ''
    $sep = $Indent ? ': ' : ':'
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return $Value ? 'true' : 'false' }
    if ($Value -is [string]) { return [HarnessJson]::Quote($Value) }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.get_Count() -eq 0) { return '{}' }
        $items = foreach ($k in $Value.get_Keys()) { (& $pad ($Level + 1)) + [HarnessJson]::Quote([string]$k) + $sep + (ConvertTo-HarnessJsonText -Value $Value[$k] -Indent $Indent -Level ($Level + 1)) }
        return '{' + $nl + ($items -join (',' + $nl)) + $nl + (& $pad $Level) + '}'
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $props = [ordered]@{}
        foreach ($p in $Value.PSObject.Properties) { $props[$p.Name] = $p.Value }
        return ConvertTo-HarnessJsonText -Value $props -Indent $Indent -Level $Level
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $arr = @($Value)
        if ($arr.Count -eq 0) { return '[]' }
        $simple = @($arr | Where-Object { $_ -is [System.Collections.IDictionary] -or $_ -is [System.Management.Automation.PSCustomObject] -or ($_ -is [System.Collections.IEnumerable] -and $_ -isnot [string]) }).Count -eq 0
        if ($simple) { return '[' + (($arr | ForEach-Object { ConvertTo-HarnessJsonText -Value $_ }) -join ', ') + ']' }
        $items = foreach ($x in $arr) { (& $pad ($Level + 1)) + (ConvertTo-HarnessJsonText -Value $x -Indent $Indent -Level ($Level + 1)) }
        return '[' + $nl + ($items -join (',' + $nl)) + $nl + (& $pad $Level) + ']'
    }
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) { return ([double]$Value).ToString('R', [Globalization.CultureInfo]::InvariantCulture) }
    if ($Value -is [ValueType]) { return ([long]$Value).ToString([Globalization.CultureInfo]::InvariantCulture) }
    throw "cannot write a $($Value.GetType().Name) as JSON"
}

Export-ModuleMember -Function ConvertFrom-HarnessJson, ConvertTo-HarnessJsonText
