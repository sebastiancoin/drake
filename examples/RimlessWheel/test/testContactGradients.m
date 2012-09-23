function testContactGradients

options.floating = true;
m = PlanarRigidBodyModel('../RimlessWheel.urdf',options);

p = TimeSteppingRigidBodyManipulator(m,.01);
x0 = p.manip.resolveConstraints([0;1+rand;randn;5*rand;randn;5*rand]);

options.grad_method = {'user','taylorvar'};
[n,D,dn,dD] = geval(2,@contactConstraintsWrapper,p.manip,x0(1:p.manip.num_q),options);

for i=1:100
  q = randn(p.manip.num_q,1); 
  [n,D,dn,dD] = geval(2,@contactConstraintsWrapper,p.manip,q,options);
end



function [n,D,dn,dD] = contactConstraintsWrapper(manip,q)
  if (nargout>2)
    [phi,n,D,mu,dn,dD] = contactConstraints(manip,q);
    dD = vertcat(dD{:});
  else
    [phi,n,D,mu] = contactConstraints(manip,q);
  end
  D = vertcat(D{:});
end

end