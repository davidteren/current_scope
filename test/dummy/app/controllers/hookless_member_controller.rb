# Deliberate misconfiguration: a MEMBER action (/hookless_member/:id) on a
# controller that never declares current_scope_record, so the gate cannot name
# the record the route points at. The Guard's contract says a member action
# needing record-level decisions must declare the hook; this is what happens
# when a host doesn't.
#
# Exists to pin that the gate fails CLOSED there. Without Guard::NO_RECORD the
# resolver would see a bare nil, read it as "collection action, no record", and
# open the gate to anyone holding a scoped grant that ticks the key — handing
# out every record of the type. Sibling of SodNilController (the A5 nil-record
# aid), for the non-SoD case.
class HooklessMemberController < ApplicationController
  include CurrentScope::Guard

  def show
    render plain: Report.find(params[:id]).title
  end
end
