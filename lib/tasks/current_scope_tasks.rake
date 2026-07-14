namespace :current_scope do
  desc "Grant the full-access Owner role to a subject (bootstrap the first admin). " \
       "Usage: bin/rails current_scope:grant SUBJECT_ID=1"
  task grant: :environment do
    id = ENV["SUBJECT_ID"]
    abort "SUBJECT_ID is required, e.g. bin/rails current_scope:grant SUBJECT_ID=1" if id.blank?

    klass = CurrentScope.config.subject_class.constantize
    subject = klass.find_by(id: id)
    abort "No #{klass} with id=#{id}" if subject.nil?

    CurrentScope.grant!(subject)
    puts "Granted the full-access Owner role to #{klass}##{subject.id}."
  end
end
