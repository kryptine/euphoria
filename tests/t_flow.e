include unittest.e

integer n,total_exit
sequence printed_i,printed_n2,loops
printed_i=repeat(0,5)
printed_n2=repeat(0,5)
total_exit=1
n=0
while n=0 label "top" do
	for i=1 to 6 do
		printed_i[n+1]=i
		if and_bits(i,1) then
			n+=1
			if n=1 then
				retry
			else
				exit
			end if
		end if
	end for
	if n=n then
	    for i=1 to 4 do
			if i=4 then
	            exit "top"
	        elsif i=2 then
	            continue
	        else
		        n+=10
	        end if
		    printed_n2[i]=n
	    end for
	end if
	total_exit=0
end while
n=2
integer p
p=0
loops={}
loop do
	n+=1
	entry
	n+=2
	p+=1 
	loops=append(loops,{n,p})
until n>10
if n>0 then
    if p=1 then
        p=-1
    else
		p=0
		break 0 -- topmost if/select
	end if
	p=-2
end if

test_equal("Retry",{1,1,0,0,0},printed_i)
test_equal("Continue",{12,0,22,0,0},printed_n2)
test_equal("Labelled exit",1,total_exit)
test_equal("Loop with entry",{{4,1},{7,2},{10,3},{13,4}},loops)
test_equal("Break with backward index",0,p)


