function [zmp_knots, body_motions] = planZMPTraj(biped, q0, footsteps, options)
% Plan the trajectories of the ZMP and the feet in order to follow the given footsteps
% @param q0 the initial configuration vector
% @param footsteps a list of Footstep objects
% @option t0 the initial time offset of the trajectories to be generated (default: 0)
% @option first_step_hold_s the number of seconds to wait before lifting the first foot (default: 1)

if nargin < 4; options = struct(); end

options = applyDefaults(options, struct('t0', 0,...
                                        'first_step_hold_s', 1.5));

target_frame_id = struct('right', biped.toe_frame_id.right,...
                         'left', biped.toe_frame_id.left);

typecheck(biped,{'RigidBodyManipulator','TimeSteppingRigidBodyManipulator'});
typecheck(q0,'numeric');
sizecheck(q0,[biped.getNumPositions,1]);

is_right_foot = footsteps(1).frame_id == biped.foot_frame_id.right;

kinsol = doKinematics(biped, q0);
foot0 = struct('right', forwardKin(biped, kinsol, biped.foot_frame_id.right, [0;0;0], 2),...
               'left', forwardKin(biped, kinsol, biped.foot_frame_id.left, [0;0;0], 2));

footsteps_with_quat = footsteps;
footsteps_with_quat(1).pos = [footsteps_with_quat(1).pos(1:3); rpy2quat(footsteps_with_quat(1).pos(4:6))];
for j = 1:2
  for f = {'right', 'left'}
    foot = f{1};
    if footsteps_with_quat(j).frame_id == biped.foot_frame_id.(foot)
      footsteps_with_quat(j).pos = foot0.(foot);
    end
  end
end
for j = 1:length(footsteps)-1
  % Make sure quaternions of adjacent steps are in the same hemisphere
  q1 = footsteps_with_quat(j).pos(4:7);
  q2 = rpy2quat(footsteps(j+1).pos(4:6));
  q2 = sign(q1' * q2) * q2;
  footsteps_with_quat(j+1).pos(4:7) = q2;
end
steps.right = footsteps_with_quat([footsteps_with_quat.frame_id] == biped.foot_frame_id.right);
steps.left = footsteps_with_quat([footsteps_with_quat.frame_id] == biped.foot_frame_id.left);

com0 = getCOM(biped, kinsol);
sole_to_com = rotmat(-footsteps(1).pos(6)) * (com0(1:2) - footsteps(1).pos(1:2));
if sole_to_com(1) < 0.01 
  % CoM is behind sole, so we have to use the heel support to get moving
  for f = {'left', 'right'}
    foot = f{1};
    for j = 1:length(steps.(foot)(1).walking_params.support_contact_groups)
      if strcmp(steps.(foot)(1).walking_params.support_contact_groups{j}, 'midfoot')
        steps.(foot)(1).walking_params.support_contact_groups{j} = 'heel';
      end
    end
  end
end

[zmp0, supp0] = getZMPBetweenFeet(biped, struct('right', steps.right(1), 'left', steps.left(1)));
zmp_knots = struct('t', options.t0, 'zmp', zmp0, 'supp', supp0);

frame_knots = struct('t', options.t0, ...
  'right', zeros(12,1),...
  'left', zeros(12,1),...
  'toe_off_allowed', struct('right', false, 'left', false));
for f = {'right', 'left'}
  foot = f{1};
  frame_id = biped.foot_frame_id.(foot);
  T = biped.getFrame(frame_id).T;
  sole_pose = steps.(foot)(1).pos;
  Tsole = [quat2rotmat(sole_pose(4:7)), sole_pose(1:3); 0 0 0 1];
  Torig = Tsole / T;
  if target_frame_id.(foot) < 0
    Tframe = Torig * biped.getFrame(target_frame_id.(foot)).T;
  else
    Tframe = Torig;
  end
  frame_knots.(foot) = [Tframe(1:3,4); quat2expmap(rotmat2quat(Tframe(1:3,1:3))); zeros(6,1)];
end

istep = struct('right', 1, 'left', 1);
is_first_step = true;

while 1
  if is_right_foot
    sw_foot = 'right'; % moving (swing) foot
    st_foot = 'left'; % stance foot
  else
    sw_foot = 'left';
    st_foot = 'right';
  end
  sw0 = steps.(sw_foot)(istep.(sw_foot));
  sw1 = steps.(sw_foot)(istep.(sw_foot)+1);
  st = steps.(st_foot)(istep.(st_foot));

  if is_first_step
    initial_hold = options.first_step_hold_s;
%     sw1.walking_params.drake_min_hold_time = options.first_step_hold_s;
    is_first_step = false;
    sw1.walking_params.step_speed = sw1.walking_params.step_speed / 2;
  else
    initial_hold = 0;
  end
  if istep.left == length(steps.left) || istep.right == length(steps.right)
    % this is the last swing, so slow down
    sw1.walking_params.step_speed = sw1.walking_params.step_speed / 2;
  end

  [new_foot_knots, new_zmp_knots] = planSwingPitched(biped, st, sw0, sw1, initial_hold, target_frame_id);
  t0 = frame_knots(end).t;
  for k = 1:length(new_foot_knots)
    new_foot_knots(k).t = new_foot_knots(k).t + t0;
  end
  for k = 1:length(new_zmp_knots)
    new_zmp_knots(k).t = new_zmp_knots(k).t + t0;
  end

  frame_knots(end).toe_off_allowed.(sw_foot) = true;
  frame_knots = [frame_knots, new_foot_knots];
  zmp_knots = [zmp_knots, new_zmp_knots];

  istep.(sw_foot) = istep.(sw_foot) + 1;

  is_right_foot = ~is_right_foot;
  if istep.left == length(steps.left) && istep.right == length(steps.right)
    break
  end
end

% add a segment at the end to recover
t0 = frame_knots(end).t;
frame_knots(end+1) = frame_knots(end);
frame_knots(end).t = t0 + 1.5;
[zmpf, suppf] = getZMPBetweenFeet(biped, struct('right', steps.right(end), 'left', steps.left(end)));
% zmpf = mean([steps.right(end).pos(1:2), steps.left(end).pos(1:2)], 2);
zmp_knots(end+1) =  struct('t', frame_knots(end-1).t, 'zmp', zmpf, 'supp', suppf);
zmp_knots(end+1) =  struct('t', frame_knots(end).t, 'zmp', zmpf, 'supp', suppf);

% dynamic_footstep_plan = DynamicFootstepPlan(biped, zmp_knots, frame_knots);

toe_off_allowed = [frame_knots.toe_off_allowed];
body_motions = BodyMotionData.empty();
for f = {'right', 'left'}
  foot = f{1};
  foot_states = [frame_knots.(foot)];
  frame_id = target_frame_id.(foot);
  ts = [frame_knots.t];
  body_motions(end+1) = BodyMotionData.from_body_xyzexp_and_xyzexpdot(frame_id, ts, foot_states(1:6,:), foot_states(7:12,:));
  body_motions(end).in_floating_base_nullspace = true(1, numel(ts));
  body_motions(end).toe_off_allowed = [toe_off_allowed.(foot)];
end

end

function [zmp, supp] = getZMPBetweenFeet(biped, steps)
  % Find the location of the ZMP at the center of the active contact points of the feet.
  % @param biped a Biped
  % @param steps a struct mapping the strings 'right' and 'left' to two Footstep objects
  zmp = zeros(2,0);
  initial_supports = [];
  initial_support_groups = {};
  for f = {'left', 'right'}
    foot = f{1};
    if steps.(foot).is_in_contact
      supp_groups = steps.(foot).walking_params.support_contact_groups;
      supp_pts = biped.getTerrainContactPoints(biped.foot_body_id.(foot), {supp_groups});
      initial_support_groups{end+1} = supp_groups;
      T_sole_to_world = poseQuat2tform(steps.(foot).pos);
      T_sole_to_foot = biped.getFrame(steps.(foot).frame_id).T;
      T_foot_to_world = T_sole_to_world / T_sole_to_foot;
      supp_pts_in_world = T_foot_to_world * [supp_pts.pts; ones(1, size(supp_pts.pts, 2))];
      zmp(:,end+1) = mean(supp_pts_in_world(1:2,:), 2);
      initial_supports(end+1) = biped.foot_body_id.(foot);
    end
  end
  zmp = mean(zmp, 2);
  supp = RigidBodySupportState(biped, initial_supports, initial_support_groups);
end