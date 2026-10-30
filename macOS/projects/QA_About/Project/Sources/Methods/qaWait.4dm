var $n : Integer
While (Not(File("/PACKAGE/about_done.txt").exists) & ($n<900))
	DELAY PROCESS(Current process; 12)
	$n:=$n+1
End while
QUIT 4D
