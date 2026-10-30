var $log; $f; $s; $ver : Text
var $i; $build : Integer
var $res : Variant
var $tests : Collection
ON ERR CALL("errH")
ERROR:=0
$ver:=Application version($build)
$log:="Version: "+Application version(*)+"\r\nBuild: "+String($build)+"\r\n"
$log:=$log+"Language: "+Get database localization(User system localization)+"\r\n"
ARRAY TEXT($comps; 0)
COMPONENT LIST($comps)
$log:=$log+"Components ("+String(Size of array($comps))+"):\r\n"
For ($i; 1; Size of array($comps))
	$log:=$log+"  "+$comps{$i}+"\r\n"
End for
ARRAY LONGINT($pnum; 0)
ARRAY TEXT($pname; 0)
PLUGIN LIST($pnum; $pname)
$log:=$log+"Plugins ("+String(Size of array($pname))+"):\r\n"
For ($i; 1; Size of array($pname))
	$log:=$log+"  "+$pname{$i}+"\r\n"
End for
$tests:=New collection("IT_SetTimeOut(30)")
For each ($f; $tests)
	$res:=Null
	ERROR:=0
	$res:=Formula from string($f).call()
	If (Value type($res)=Is undefined)
		$s:="UNDEFINED"
	Else 
		$s:=JSON Stringify($res)
	End if 
	$log:=$log+"TEST "+$f+" => "+$s+" (err "+String(ERROR)+")\r\n"
End for each
ON ERR CALL("")
File("/PACKAGE/qa_result.txt").setText($log; "UTF-8-no-bom")
QUIT 4D
