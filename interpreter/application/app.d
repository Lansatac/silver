module application.app;

import silver.grammar;
import silver.interpreter;

///Application entry point
int main(string[] args)
{
	interpret(`
	var a = 5
	var b = a
	print a
	print b
	`);

	return 0;
}
