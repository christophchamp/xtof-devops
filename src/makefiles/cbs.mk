%.cai:	%.tab
	perl -e '%val = ("AA", -1.11, "AC", -1.81, "AG", -1.06, "AT", -1.81, "CA", -0.55, "CC", -1.44, "CG", -0.91, "CT", -1.06, "GA", -1.43, "GC", -2.17, "GG", -1.44, "GT", -1.81, "TA", -0.19, "TC", -1.43, "TG", -0.55, "TT", -1.11); while (<>) {@seq = split(/\t/, $$_); for ($$i = 0; $$i+2 <= length($$seq[1]); $$i++) {if (defined($$val{substr($$seq[1], $$i, 2)})) {printf("%.3f\n", $$val{substr($$seq[1], $$i, 2)});} else {print "\n";}}}' $< > $@