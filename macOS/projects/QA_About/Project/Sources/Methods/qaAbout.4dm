// About box test: writes the version, then keeps 4D open until the About box has been read (about_done.txt)
var $log; $ver : Text
var $build : Integer
ON ERR CALL("errH")
$ver:=Application version($build)
$log:="Version: "+Application version(*)+"\r\nBuild: "+String($build)+"\r\n"
$log:=$log+"Language: "+Get database localization(User system localization)+"\r\n"
ON ERR CALL("")
File("/PACKAGE/qa_result.txt").setText($log; "UTF-8-no-bom")
CALL WORKER("qaWait"; "qaWait")
