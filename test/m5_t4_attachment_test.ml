open Campfire

let asset name = try Assets.asset_path name with _ -> "/assets/" ^ name

let test_file_attachment_presentation () =
  let user : Views.user = {id=1L;name="Bot";title="Bot";
    avatar_url="/avatar";role="bot"} in
  let file : Views.attachment = {filename="report<&>.txt";
    blob_path="/blob/1";download_path="/blob/1?x=1&y=2";
    preview_url=None} in
  let message : Views.message = {id=2L;client_message_id="bot-file";
    room_id=3L;room_name="Room";creator=user;created_at_iso="2026-10-09T12:00:00Z";
    created_at_ms=0L;updated_at_ms=0L;all_emoji=false;
    content=Views.Attachment file;editable_body="";boosts=[]} in
  let expected=Printf.sprintf
    "<div class=\"flex-inline align-center gap-half\"><img class=\"colorize--black\" aria-hidden=\"true\" src=\"%s\" width=\"22\" height=\"22\" /><span>report&lt;&amp;&gt;.txt</span><a class=\"btn message__action-btn hide-in-ios-pwa\" style=\"--width: auto;\" href=\"/blob/1?x=1&amp;y=2\"><img aria-hidden=\"true\" src=\"%s\" width=\"20\" height=\"20\" /><span class=\"for-screen-reader\">Download report&lt;&amp;&gt;.txt</span></a><button class=\"btn message__action-btn\" style=\"--width: auto;\" data-controller=\"web-share\" data-action=\"web-share#share\" data-web-share-files-value=\"/blob/1?x=1&amp;y=2\"><img aria-hidden=\"true\" src=\"%s\" width=\"20\" height=\"20\" /><span class=\"for-screen-reader\">Share report&lt;&amp;&gt;.txt</span></button></div>"
    (asset "common-file-text.svg") (asset "download.svg")
    (asset "share.svg") in
  Alcotest.(check string) "Rails/Rust attachment HTML"
    expected (Views.render (Views.message_presentation message))

let ()=Alcotest.run "M5-T4 attachment differential" [
  "presentation",[Alcotest.test_case "exact bot file HTML" `Quick
    test_file_attachment_presentation]]
