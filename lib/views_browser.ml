(* The allow_browser before-action renders this static Rails template for old
   supported-browser versions. This module stays independent of Http_app so the
   request boundary can call it without a presentation-layer cycle. *)
module H = Tyxml.Html
let attr (name,value) = H.Unsafe.string_attrib name value
let node name attributes children =
  H.Unsafe.node name ~a:(List.map attr attributes) children
let leaf name attributes = H.Unsafe.leaf name ~a:(List.map attr attributes) ()
let txt = H.txt
let html elt = Format.asprintf "%a" (H.pp_elt ()) elt

let translations = [
  "🇺🇸", "Upgrade to a supported web browser. Campfire requires a modern web browser. Please use one of the browsers listed below and make sure auto-updates are enabled.";
  "🇪🇸", "Actualiza a un navegador web compatible. Campfire requiere un navegador web moderno. Utiliza uno de los navegadores listados a continuación y asegúrate de que las actualizaciones automáticas estén habilitadas.";
  "🇫🇷", "Mettez à jour vers un navigateur web pris en charge. Campfire nécessite un navigateur web moderne. Veuillez utiliser l'un des navigateurs répertoriés ci-dessous et assurez-vous que les mises à jour automatiques sont activées.";
  "🇮🇳", "समर्थित वेब ब्राउज़र में अपग्रेड करें। Campfire को एक आधुनिक वेब ब्राउज़र की आवश्यकता है। कृपया नीचे सूचीबद्ध ब्राउज़रों में से कोई एक का उपयोग करें और सुनिश्चित करें कि स्वचालित अपडेट्स सक्षम हैं।";
  "🇩🇪", "Aktualisieren Sie auf einen unterstützten Webbrowser. Campfire erfordert einen modernen Webbrowser. Verwenden Sie bitte einen der unten aufgeführten Browser und stellen Sie sicher, dass automatische Updates aktiviert sind.";
  "🇧🇷", "Atualize para um navegador compatível. O Campfire requer um navegador moderno. Por favor, use um dos navegadores listados abaixo e certifique-se de que as atualizações automáticas estão ativadas.";
  "🇯🇵", "サポートされたウェブブラウザーにアップグレードしてください。Campfireはモダンなウェブブラウザーが必要です。下記のブラウザーのいずれかを使用し、自動更新が有効になっていることを確認してください。";
]
let translation_button asset =
  node "details" ["class","position-relative";"data-controller","popup";
    "data-action","keydown.esc->popup#close toggle->popup#toggle click@document->popup#closeOnClickOutside";
    "data-popup-orientation-top-class","popup-orientation-top"] [
    node "summary" ["class","btn";"tabindex","-1"] [
      leaf "img" ["aria-hidden","true";"class","color-icon";"src",asset "globe.svg";
        "width","20";"height","20"];
      node "span" ["class","for-screen-reader"] [txt "Translate"]];
    node "div" ["class","language-list-menu shadow";"data-popup-target","menu"] [
      node "dl" ["class","language-list"] (List.concat_map (fun (flag,message) -> [
        node "dt" [] [txt flag];node "dd" ["class","margin-none"] [txt message]]) translations)]]
let content asset =
  let browser_item (browser,version) =
    node "div" ["class","browser flex flex-column"] [
      leaf "img" ["src",asset ("browsers/" ^ browser ^ ".svg");"aria-hidden","true";"class","center"];
      node "div" ["class","flex flex-column align-center margin-block-start-half"] [
        node "strong" [] [txt (String.capitalize_ascii browser)];
        node "span" [] [txt (" " ^ version ^ "+")]]] in
  node "div" ["class","panel center"] [
    node "header" [] [
      node "h1" ["class","txt-x-large txt-tight-lines txt-align-center margin-none-block-start margin-block-end"]
        [txt "Upgrade to a supported web browser"];
      node "div" ["class","flex align-start gap"] [
        translation_button asset;
        node "p" ["class","margin-none-block-start"]
          [txt "Campfire requires a modern web browser. Please use one of the browsers listed below and make sure auto-updates are enabled."]]];
    node "div" ["class","browser-list flex align-center flex-wrap gap justify-center margin-block"]
      (List.map browser_item ["safari","17.2";"chrome","120";"firefox","121";"opera","104"])]
let timestamp_number stamp =
  let digits=String.to_seq stamp |> List.of_seq |> List.filter (function '0'..'9' -> true | _ -> false)
    |> List.to_seq |> String.of_seq in
  if String.length digits>=14 then String.sub digits 0 14 else digits
let context account =
  let assets = List.map (fun (logical,digested) -> logical,"/assets/"^digested)
    (Lazy.force Assets.manifest) in
  let stylesheet_tags = fst (Assets.stylesheet_tags ()) |> Views.trusted_html_of_sanitized in
  let importmap_tags = Assets.javascript_importmap_tags () |> Views.trusted_html_of_sanitized in
  let account_name = match account with None -> "Campfire" | Some (a:Db_accounts.Account.t) -> a.name in
  let custom_styles = Option.bind account (fun (a:Db_accounts.Account.t) -> a.custom_styles) in
  let logo_url=Route_helpers.fresh_account_logo
    ?v:(Option.map (fun (a:Db_accounts.Account.t) -> timestamp_number a.updated_at) account) () in
  { Views.default_context with account_name;custom_styles;logo_url;assets;
    stylesheet_tags=Some stylesheet_tags;importmap_tags=Some importmap_tags }
let render ?(frame=false) ~account ~view () =
  let ctx=context account in
  let asset name=Views.asset ctx name in
  let body=html (content asset) in
  if frame then "<html><head></head><body>" ^ body ^ "</body></html>"
  else let fragment=Views.trusted_html_of_sanitized body in
    (* [body] is generated solely by Tyxml from static text and manifest paths. *)
    Views.page ~title:(if view.User_agent.apple_messages then "Campfire" else "Unsupported browser")
      ~context:ctx (Views.raw fragment)
