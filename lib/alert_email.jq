# Alert e-mail body (text or HTML). Input is the `render json` document.
# Args: $mode (text|html), $host, $tool (e.g. "rds_backup_compliance_report.sh v1.7.2"),
#       $when (timestamp for the footer).
# Named constants below are typography only (same colours as the HTML report); every
# setting still comes from the conf / CLI, not from this file.
def lab:
  if ((.account_name // "") != "") then "\(.account_name) (\(.account_id))"
  elif ((.name // "") != "") then "\(.name) (\(.account // .account_id))"
  else (.account_id // .account // "") end;
def dash: if . == null or . == "" then "—" else . end;
def rpad($w): tostring + (" " * ([0, $w - (tostring | length)] | max));
def nc_rows: [.rows[]? | select(.status == "NON-COMPLIANT")];
def un_rows: [.rows[]? | select(.status == "UNKNOWN")];
def re_rows: [.regions[]? | select(.status == "error")];
def as_fail($kind):
  if $kind == "region" then
    {account: (if ((.account_name // "") != "") then "\(.account_name) (\(.account))"
               elif ((.name // "") != "") then "\(.name) (\(.account))"
               else (.account // "") end),
     server: "—", region: (.region // ""), engine: "—",
     missing: ((.errors // []) | join("; "))}
  else
    {account: lab, server: (.identifier // ""), region: (.region // ""),
     engine: (.engine // ""), missing: (.gaps // "")}
  end;
def acct_list:
  ([.accounts[]? | if (.name // "") != "" then "\(.name) (\(.account))" else .account end] | join(", "));
def status_word:
  if .totals.non_compliant > 0 then "NON-COMPLIANT"
  elif ((un_rows | length) + (re_rows | length)) > 0 then "ERRORS"
  else "COMPLIANT" end;
# typography (matches the HTML report; not conf settings)
def col_red: "#b3261e";
def col_green: "#137333";
def col_amber: "#b54708";
def banner_bg:
  if status_word == "NON-COMPLIANT" then col_red
  elif status_word == "ERRORS" then col_amber
  else col_green end;
def footer:
  "\($tool)"
  + (if $host != "" then " · \($host)" else "" end)
  + (if $when != "" then " · \($when)" else "" end);
def counts_text:
  "Resources: \(.totals.resources)\n"
  + "Compliant: \(.totals.compliant)\n"
  + "Non-compliant: \(.totals.non_compliant)\n"
  + "Not yet due: \(.totals.not_yet_due)\n"
  + "Unknown: \(.totals.unknown)\n"
  + "Compliance: \(.totals.compliance.pct // 0)% (\(.totals.compliance.compliant) of \(.totals.compliance.of); not yet due not counted)"
  + (if (.totals.exceptions.applied // 0) > 0 then ", incl. \(.totals.exceptions.applied) exception(s)" else "" end);
def text_table($title; $rows):
  if ($rows | length) == 0 then empty else
    ($rows | length) as $n
    | ["Account", "Server", "Region", "Engine", "What's missing"] as $h
    | ($rows | map([.account, .server, .region, .engine, .missing])) as $d
    | [0,1,2,3,4] as $ix
    | ($ix | map( . as $i | ([$h[$i]] + [$d[][$i]] | map(length) | max) )) as $w
    | ($title + " (\($n)):",
       "",
       ($ix | map(. as $i | $h[$i] | rpad($w[$i])) | join("  ")),
       ($ix | map(. as $i | "-" * $w[$i]) | join("  ")),
       ($d[] | . as $r | ($ix | map(. as $i | $r[$i] | rpad($w[$i])) | join("  "))),
       "")
  end;
def text_body:
  status_word as $st
  | ("RDS backup compliance: \($st)",
     "\(.totals.non_compliant) non-compliant of \(.totals.resources) servers, \(.totals.compliance.pct // 0)% compliant",
     "",
     "Accounts: \(acct_list)",
     counts_text,
     "",
     (if (nc_rows | length) == 0 and (un_rows | length) == 0 and (re_rows | length) == 0 then
        "No NON-COMPLIANT servers."
      else empty end),
     (text_table("NON-COMPLIANT servers"; [nc_rows[] | as_fail("row")])),
     (text_table("UNKNOWN (an AWS call failed)"; [un_rows[] | as_fail("row")])),
     (text_table("Region errors"; [re_rows[] | as_fail("region")])),
     "",
     footer);

def th($s):
  "<th align=\"left\" style=\"border:1px solid #d0d5dd;background:#f2f4f7;padding:8px 10px;font-size:11px;text-transform:uppercase;letter-spacing:.03em;color:#475467;\">\($s | @html)</th>";
def td($s; $extra):
  "<td style=\"border:1px solid #d0d5dd;padding:8px 10px;font-size:13px;line-height:1.4;vertical-align:top;\($extra)\">\($s | dash | @html)</td>";
def html_table($title; $rows):
  if ($rows | length) == 0 then "" else
    "<tr><td style=\"padding:8px 20px 4px;font-size:14px;font-weight:700;\">\($title | @html) (\($rows | length))</td></tr>\n"
    + "<tr><td style=\"padding:0 20px 16px;\">\n"
    + "<table width=\"100%\" cellspacing=\"0\" cellpadding=\"0\" style=\"border-collapse:collapse;width:100%;\">\n"
    + "<thead><tr>" + th("Account") + th("Server") + th("Region") + th("Engine") + th("What's missing") + "</tr></thead>\n"
    + "<tbody>\n"
    + ($rows | map(
        "<tr>"
        + td(.account; "")
        + td(.server; "font-weight:600;")
        + td(.region; "white-space:nowrap;")
        + td(.engine; "white-space:nowrap;")
        + td(.missing; "")
        + "</tr>"
      ) | join("\n"))
    + "\n</tbody></table>\n</td></tr>\n"
  end;
def html_body:
  status_word as $st
  | (banner_bg) as $bg
  | ("<!DOCTYPE html>\n<html lang=\"en\"><head>\n"
     + "<meta charset=\"utf-8\">\n"
     + "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
     + "<title>RDS backup compliance: \($st | @html)</title>\n"
     + "</head>\n"
     + "<body style=\"margin:0;padding:0;background:#f2f4f7;font-family:Arial,Helvetica,sans-serif;color:#1d2939;\">\n"
     + "<table role=\"presentation\" width=\"100%\" cellspacing=\"0\" cellpadding=\"0\" style=\"background:#f2f4f7;padding:0;\">\n"
     + "<tr><td align=\"center\">\n"
     + "<table role=\"presentation\" width=\"680\" cellspacing=\"0\" cellpadding=\"0\" style=\"width:680px;max-width:680px;background:#ffffff;border:1px solid #d0d5dd;\">\n"
     + "<tr><td style=\"padding:16px 20px;background:\($bg);color:#ffffff;\">\n"
     + "<div style=\"font-size:11px;letter-spacing:.04em;text-transform:uppercase;opacity:.9;\">RDS backup compliance</div>\n"
     + "<div style=\"font-size:20px;font-weight:700;margin-top:4px;\">\($st | @html)</div>\n"
     + "<div style=\"font-size:13px;margin-top:4px;\">\(.totals.non_compliant) non-compliant of \(.totals.resources) servers · \(.totals.compliance.pct // 0)% compliant</div>\n"
     + "</td></tr>\n"
     + "<tr><td style=\"padding:16px 20px 8px;font-size:14px;line-height:1.5;\">\n"
     + "<div style=\"margin-bottom:10px;\"><b>Accounts:</b> \(acct_list | @html)</div>\n"
     + "<table role=\"presentation\" cellspacing=\"0\" cellpadding=\"0\" style=\"border-collapse:collapse;\">\n"
     + "<tr>\n"
     + "<td style=\"padding:8px 14px 8px 0;border-right:1px solid #e4e7ec;\"><div style=\"font-size:11px;color:#667085;\">Resources</div><div style=\"font-size:18px;font-weight:700;\">\(.totals.resources)</div></td>\n"
     + "<td style=\"padding:8px 14px;border-right:1px solid #e4e7ec;\"><div style=\"font-size:11px;color:#667085;\">Compliant</div><div style=\"font-size:18px;font-weight:700;color:\(col_green);\">\(.totals.compliant)</div></td>\n"
     + "<td style=\"padding:8px 14px;border-right:1px solid #e4e7ec;\"><div style=\"font-size:11px;color:#667085;\">Non-compliant</div><div style=\"font-size:18px;font-weight:700;color:\(col_red);\">\(.totals.non_compliant)</div></td>\n"
     + "<td style=\"padding:8px 14px;border-right:1px solid #e4e7ec;\"><div style=\"font-size:11px;color:#667085;\">Not yet due</div><div style=\"font-size:18px;font-weight:700;\">\(.totals.not_yet_due)</div></td>\n"
     + "<td style=\"padding:8px 14px;\"><div style=\"font-size:11px;color:#667085;\">Unknown</div><div style=\"font-size:18px;font-weight:700;\">\(.totals.unknown)</div></td>\n"
     + "</tr></table>\n"
     + "<div style=\"font-size:12px;color:#667085;margin-top:8px;\">Compliance is \(.totals.compliance.pct // 0)% (\(.totals.compliance.compliant) of \(.totals.compliance.of)). Servers that are not yet due are not counted in the percentage."
     + (if (.totals.exceptions.applied // 0) > 0 then " Includes \(.totals.exceptions.applied) exception(s)." else "" end)
     + "</div>\n"
     + "</td></tr>\n"
     + (if (nc_rows | length) == 0 and (un_rows | length) == 0 and (re_rows | length) == 0 then
         "<tr><td style=\"padding:8px 20px 16px;font-size:14px;\">No NON-COMPLIANT servers.</td></tr>\n"
       else
         html_table("NON-COMPLIANT servers"; [nc_rows[] | as_fail("row")])
         + html_table("UNKNOWN (an AWS call failed)"; [un_rows[] | as_fail("row")])
         + html_table("Region errors"; [re_rows[] | as_fail("region")])
       end)
     + "<tr><td style=\"padding:12px 20px;border-top:1px solid #e4e7ec;font-size:11px;color:#667085;\">\(footer | @html)</td></tr>\n"
     + "</table>\n</td></tr></table>\n</body></html>\n");

if $mode == "html" then html_body else text_body end
